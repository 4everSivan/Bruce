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
        AclSizeInformation,
        Authorization::{ConvertSidToStringSidW, GetNamedSecurityInfoW, SE_FILE_OBJECT},
        GetAce, GetAclInformation, GetSecurityDescriptorControl, ACCESS_ALLOWED_ACE,
        ACL_SIZE_INFORMATION, SE_DACL_PROTECTED,
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
    let (mut present, mut defaulted, mut acl) = (0, 0, ptr::null_mut());
    // SAFETY: valid descriptor; the ACL pointer belongs to the descriptor lifetime.
    if unsafe { GetSecurityDescriptorDacl(descriptor, &mut present, &mut acl, &mut defaulted) } == 0
        || present == 0
        || acl.is_null()
    {
        return Err("ACL 缺少访问控制表".to_owned());
    }
    // SAFETY: GetNamedSecurityInfoW returned a valid PACL for this descriptor.
    let acl = unsafe { &*acl };
    let mut size = ACL_SIZE_INFORMATION {
        AceCount: 0,
        AclBytesInUse: 0,
        AclBytesFree: 0,
    };
    // SAFETY: acl is a valid ACL; output struct has the documented size.
    if unsafe {
        GetAclInformation(
            acl,
            &mut size as *mut _ as *mut c_void,
            std::mem::size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        )
    } == 0
    {
        return Err("读取访问控制表大小失败".to_owned());
    }
    if size.AceCount != 1 {
        return Err(format!("ACE 数量应为 1, 实际 {}", size.AceCount));
    }
    let mut ace = ptr::null_mut();
    // SAFETY: index 0 exists because AceCount is 1.
    if unsafe { GetAce(acl, 0, &mut ace) } == 0 || ace.is_null() {
        return Err("读取访问条目失败".to_owned());
    }
    // SAFETY: our own DACL only ever holds access-allowed ACEs.
    let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
    if allowed.Header.AceType != 0 {
        return Err("访问条目不是允许类型".to_owned());
    }
    let mut string_sid = ptr::null_mut();
    // SAFETY: SidStart is the inline SID of the single allowed ACE.
    if unsafe {
        ConvertSidToStringSidW(ptr::addr_of!(allowed.SidStart).cast_mut(), &mut string_sid)
    } == 0
    {
        return Err("读取访问条目身份失败".to_owned());
    }
    let _owned_sid = LocalBuffer(string_sid.cast());
    let mut len = 0;
    // SAFETY: ConvertSidToStringSidW returns a terminated UTF-16 SID string.
    let actual_sid = unsafe {
        while *string_sid.add(len) != 0 {
            len += 1;
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(string_sid, len))
    };
    let sid = current_sid()?;
    // 注: 不比对 SDDL 字符串 — 已知账户 (如内置 Administrator RID-500, CI runner 用户)
    // 会被序列化为 SDDL 别名 (LA/BA), 字符串比对在 windows-latest 上必然误报;
    // ACE 级 SID 相等才是唯一在案身份判定。
    if actual_sid != sid {
        return Err(format!(
            "ACL 身份与当前用户不一致: ace={actual_sid} current={sid}"
        ));
    }
    Ok(())
}
