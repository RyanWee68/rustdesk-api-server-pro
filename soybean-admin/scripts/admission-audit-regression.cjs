const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { createRequire } = require('node:module');
const { compileScript, parse } = require('vue/compiler-sfc');
const ts = require('typescript');
const vue = require('vue');
const { renderToString } = require('vue/server-renderer');
const { NDataTable, NCode } = require('naive-ui');
const { setup: setupSsr } = createRequire(require.resolve('naive-ui'))('@css-render/vue3-ssr');

// 编译真实页面脚本，仅替换联网和应用全局依赖；表格及详情组件使用实际实现。
const source = readFileSync(resolve(__dirname, '../src/views/audit/admissionlogs/index.vue'), 'utf8');
const { descriptor } = parse(source);
const script = compileScript(descriptor, { id: 'admission-audit-regression' });
const { outputText } = ts.transpileModule(script.content, {
  compilerOptions: {
    module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2022,
    jsx: ts.JsxEmit.React,
    jsxFactory: 'h'
  }
});
const compiled = { exports: {} };
/** 隔离联网及全局状态，保留真实 Vue 和组件库。 */
function pageRequire(name) {
  if (name === '@/locales') return { $t: key => key };
  if (name === '@/store/modules/app') return { useAppStore: () => ({ isMobile: false }) };
  if (name === '@/service/api/audit') {
    return { fetchAdmissionAuditLogList: () => { throw new Error('ERR-1000: 回归测试禁止联网'); } };
  }
  return require(name);
}
new Function('require', 'module', 'exports', 'h', outputText)(pageRequire, compiled, compiled.exports, vue.h);

/** 验证业务错误行、展开入口和详情文本传参。 */
async function main() {
  const rows = Array.from({ length: 14 }, (_, index) => ({
    id: index + 1,
    action: 'rustdesk_internal_connection_check',
    rustdesk_id: 'test-device',
    result: index % 2 ? 'error' : 'deny',
    code: `ERR-${2302 + index}`,
    ip: '127.0.0.1',
    user_agent: 'regression',
    created_at: '2026-10-14 00:00:00',
    request: JSON.stringify({ marker: `request-${index}`, text: '<script>alert(1)</script>' }),
    response: JSON.stringify({ code: `ERR-${2302 + index}`, marker: `response-${index}` })
  }));
  rows[0].request = 'invalid-json-request';
  rows[1].response = '';
  let columns;
  const app = vue.createSSRApp({
    setup() {
      const state = compiled.exports.default.setup({}, { expose() {} });
      columns = state.columns;
      assert.equal(columns.filter(column => column.type === 'expand').length, 1);
      return () => vue.h(NDataTable, {
        columns,
        data: rows,
        rowKey: row => row.id,
        expandedRowKeys: rows.map(row => row.id)
      });
    }
  });
  setupSsr(app);
  const html = await renderToString(app);
  for (const row of rows) assert.ok(html.includes(row.code), `未显示 ${row.code}`);
  assert.equal((html.match(/class="n-code /g) || []).length, rows.length * 2);
  const expand = columns.find(column => column.type === 'expand');
  // NCode 在浏览器挂载后才填充正文，SSR 中核对实际详情节点传入的文本。
  for (const row of rows) {
    const details = expand.renderExpand(row).children;
    assert.equal(details.length, 2);
    for (const [index, field] of ['request', 'response'].entries()) {
      assert.equal(details[index].type, NCode);
      let expected;
      try { expected = row[field] ? JSON.parse(row[field]) : {}; } catch { expected = row[field]; }
      assert.equal(details[index].props.code, JSON.stringify(expected, null, 2));
      assert.equal(details[index].props.innerHTML, undefined);
    }
  }
  assert.ok(!html.includes('<script>'));
  console.log('准入日志回归通过：14 个错误码、28 个真实详情节点、异常 JSON 与纯文本传参。');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
