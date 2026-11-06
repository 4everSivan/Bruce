/*!
 * 本地预览兜底：不参与构建注入逻辑。
 *
 * 直接用静态服务器打开 `website/index.html` 时，页面里仍是构建期占位符
 * （{{VERSION}} / {{DMG_SIZE}} / {{EXE_SIZE}}），看起来像坏掉了。
 * 本脚本检测到占位符后读取仓库根的 VERSION 文件并替换，让预览显示真实版本号；
 * 构建产物（local/dist/site）里的占位符早已被 scripts/build-site.mjs 替换，
 * 因此本脚本在正式页面上不会做任何改动。
 */
(function () {
  "use strict";

  if (document.documentElement.innerHTML.indexOf("{{") === -1) return;

  var TOKEN = /\{\{(VERSION|DMG_SIZE|EXE_SIZE)\}\}/g;
  var version = null;

  function substitute(value, forAttribute) {
    return value.replace(TOKEN, function (match, key) {
      if (key === "VERSION") return version || "dev";
      return forAttribute ? "" : "—";
    });
  }

  function walk(node) {
    if (node.nodeType === 3) {
      if (node.nodeValue.indexOf("{{") !== -1) node.nodeValue = substitute(node.nodeValue, false);
      return;
    }
    if (node.nodeType !== 1) return;
    var attrs = node.attributes;
    var i;
    for (i = 0; i < attrs.length; i += 1) {
      if (attrs[i].value.indexOf("{{") !== -1) attrs[i].value = substitute(attrs[i].value, true);
    }
    for (var child = node.firstChild; child; child = child.nextSibling) walk(child);
  }

  function apply(v) {
    version = v;
    walk(document.body);
    walk(document.head);
  }

  function tryNext(paths, index) {
    if (index >= paths.length) { apply(null); return; }
    fetch(paths[index], { cache: "no-store" })
      .then(function (response) {
        if (!response.ok) throw new Error(String(response.status));
        return response.text();
      })
      .then(function (text) {
        var v = text.trim();
        if (/^\d+\.\d+\.\d+$/.test(v)) apply(v);
        else tryNext(paths, index + 1);
      })
      .catch(function () { tryNext(paths, index + 1); });
  }

  var dir = location.pathname.replace(/[^/]*$/, "");
  tryNext([dir + "VERSION", dir + "../VERSION", "/VERSION"], 0);
})();
