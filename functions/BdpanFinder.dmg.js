// /BdpanFinder.dmg —— 302 跳到最新 release 的 .dmg 资产，并走 jianshuo.dev/gh 代理，
// 让访问不了 github.com 的用户也能下。每次请求都解析 latest release，发新版本不用改这里。
// 之前这个路径没有真实文件，被静态站的兜底吞成了 index.html（下载下来是个 HTML），本函数修掉它。
// 边缘缓存 5 分钟，挡住对 GitHub API 的重复请求（未鉴权 60 次/小时/IP）。

const REPO = 'jianshuo/bdpan-finder';
const RELEASES = `https://github.com/${REPO}/releases/latest`;

export async function onRequest() {
  let assetUrl;
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { 'user-agent': 'bdpan-finder-site', 'accept': 'application/vnd.github+json' },
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    if (r.ok) {
      const rel = await r.json();
      const dmg = (rel.assets || []).find((a) => a.name.toLowerCase().endsWith('.dmg'));
      if (dmg && rel.tag_name) {
        // 经 jianshuo.dev/gh 代理下载，附件名由代理透传 GitHub 的 content-disposition。
        assetUrl = `https://jianshuo.dev/gh/${REPO}/releases/download/${rel.tag_name}/${encodeURIComponent(dmg.name)}`;
      }
    }
  } catch (_) {
    // 落到下面的兜底
  }
  // 兜底：解析不到资产就跳 GitHub 的 releases/latest 页（能连 github.com 的用户照样能下）。
  return Response.redirect(assetUrl || RELEASES, 302);
}
