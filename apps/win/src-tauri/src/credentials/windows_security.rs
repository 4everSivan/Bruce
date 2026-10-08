//! Small Win32 boundary. No username lookup, inherited grants, shell, or
//! best-effort fallback; each OS error aborts the secret write.
use std::{ffi::c_void, os::windows::ffi::OsStrExt, path::Path, ptr};
use windows_sys::Win32::{
    Foundation::{CloseHandle, LocalFree, ERROR_SUCCESS, HANDLE},
    Security::{
        Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
            SetNamedSecurityInfoW, SE_FILE_OBJECT,
        },
        GetSecurityDescriptorDacl, GetTokenInformation, TokenUser, DACL_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION, TOKEN_QUERY, TOKEN_USER,
    },
    Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH},
    System::Threading::{GetCurrentProcess, OpenProcessToken},
};

struct Token(HANDLE);
impl Drop for Token {
    fn drop(&mut self) {
        // SAFETY: owns the successfully opened process token handle.
        unsafe {
            CloseHandle(self.0);
        }
    }
}
struct LocalBuffer(*mut c_void);
impl Drop for LocalBuffer {
    fn drop(&mut self) {
        // SAFETY: owns an allocation returned by a Win32 LocalAlloc API.
        unsafe {
            LocalFree(self.0);
        }
    }
}
fn wide_path(path: &Path) -> Result<Vec<u16>, String> {
    let value: Vec<_> = path.as_os_str().encode_wide().collect();
    if value.contains(&0) {
        return Err("凭证路径无效".to_owned());
    }
    Ok(value.into_iter().chain(Some(0)).collect())
}
fn current_sid() -> Result<String, String> {
    let mut handle = ptr::null_mut();
    // SAFETY: valid process pseudo-handle and writable output HANDLE slot.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut handle) } == 0 {
        return Err("无法取得当前用户安全身份".to_owned());
    }
    let token = Token(handle);
    let mut size = 0;
    // SAFETY: documented size-query call; no output buffer is supplied.
    unsafe {
        GetTokenInformation(token.0, TokenUser, ptr::null_mut(), 0, &mut size);
    }
    if size < std::mem::size_of::<TOKEN_USER>() as u32 || size > 65_536 {
        return Err("当前用户安全身份大小无效".to_owned());
    }
    // usize storage gives the TOKEN_USER pointer native alignment.
    let mut buffer = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: buffer is aligned and contains at least size writable bytes.
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            size,
            &mut size,
        )
    } == 0
    {
        return Err("无法读取当前用户安全身份".to_owned());
    }
    // SAFETY: successful TokenUser query populated the aligned TOKEN_USER.
    let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    let mut string_sid = ptr::null_mut();
    // SAFETY: the SID points into the live token information buffer.
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut string_sid) } == 0 {
        return Err("无法转换当前用户安全身份".to_owned());
    }
    let _owned = LocalBuffer(string_sid.cast());
    let mut len = 0;
    // SAFETY: ConvertSidToStringSidW returns a terminated UTF-16 SID string.
    unsafe {
        while *string_sid.add(len) != 0 {
            len += 1;
        }
        String::from_utf16(std::slice::from_raw_parts(string_sid, len))
            .map_err(|_| "当前用户安全身份编码无效".to_owned())
    }
}

pub(super) fn restrict(path: &Path, directory: bool) -> Result<(), String> {
    let sid = current_sid()?;
    let inheritance = if directory { "OICI" } else { "" };
    // D:P drops inheritance. The new DACL contains exactly one current-user ACE.
    let sddl: Vec<u16> = format!("D:P(A;{inheritance};FA;;;{sid})")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut descriptor = ptr::null_mut();
    // SAFETY: terminated SDDL and writable descriptor pointer; revision 1.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err("无法建立凭证安全描述符".to_owned());
    }
    let _owned = LocalBuffer(descriptor);
    let (mut present, mut defaulted, mut acl) = (0, 0, ptr::null_mut());
    // SAFETY: descriptor lives through the ACL update call below.
    if unsafe { GetSecurityDescriptorDacl(descriptor, &mut present, &mut acl, &mut defaulted) } == 0
        || present == 0
        || acl.is_null()
    {
        return Err("凭证安全描述符缺少访问控制表".to_owned());
    }
    let name = wide_path(path)?;
    // SAFETY: all pointer arguments refer to live valid Win32 structures.
    let result = unsafe {
        SetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            ptr::null_mut(),
            ptr::null_mut(),
            acl,
            ptr::null(),
        )
    };
    if result != ERROR_SUCCESS {
        return Err("无法设置当前用户专属凭证权限".to_owned());
    }
    Ok(())
}

pub(super) fn replace(source: &Path, target: &Path) -> Result<(), String> {
    // Both names are in the same directory. No COPY_ALLOWED fallback can lose
    // the source DACL, and replacing a prior file is supported on Windows.
    let source = wide_path(source)?;
    let target = wide_path(target)?;
    // SAFETY: valid terminated paths, no pointer retention by MoveFileExW.
    if unsafe {
        MoveFileExW(
            source.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        return Err("凭证原子替换失败".to_owned());
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn assert_current_sid_only(path: &Path) -> Result<(), String> {
    use windows_sys::Win32::Security::{
        Authorization::{
            ConvertSecurityDescriptorToStringSecurityDescriptorW, GetNamedSecurityInfoW,
        },
        GetSecurityDescriptorControl, SE_DACL_PROTECTED,
    };
    let name = wide_path(path)?;
    let mut descriptor = ptr::null_mut();
    // SAFETY: valid path/output pointer. Descriptor is released by LocalBuffer.
    let result = unsafe {
        GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if result != ERROR_SUCCESS {
        return Err("读取 ACL 失败".to_owned());
    }
    let _owned = LocalBuffer(descriptor);
    let (mut control, mut revision) = (0, 0);
    // SAFETY: valid descriptor and writable control/revision slots.
    if unsafe { GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) } == 0
        || control & SE_DACL_PROTECTED == 0
    {
        return Err("ACL 继承未关闭".to_owned());
    }
    let mut text = ptr::null_mut();
    // SAFETY: valid descriptor; returned text is a LocalAlloc string.
    if unsafe {
        ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor,
            1,
            DACL_SECURITY_INFORMATION,
            &mut text,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err("读取 ACL 字符串失败".to_owned());
    }
    let _owned_text = LocalBuffer(text.cast());
    let mut len = 0;
    // SAFETY: returned UTF-16 string is terminated by Win32 contract.
    let actual = unsafe {
        while *text.add(len) != 0 {
            len += 1;
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(text, len))
    };
    let sid = current_sid()?;
    if actual.matches('(').count() != 1 || !actual.contains(&format!(";;;{sid})")) {
        // 诊断现场: CI 环境与本地 SDDL 形态可能不同 (如 ACE flags 序), 输出实况定位。
        return Err(format!(
            "ACL 含有当前用户以外的访问条目: sddl={actual} 期望 sid={sid}"
        ));
    }
    Ok(())
}
