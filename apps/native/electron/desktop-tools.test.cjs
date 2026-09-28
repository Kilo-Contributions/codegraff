const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { tools, callTool } = require('./desktop-tools.cjs');
test('desktop tools transport chat context, report errors, and preserve native image blocks', async () => {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    requests.push({ url: req.url, token: req.headers.authorization, body });
    if (body.method === 'screenshot') res.end(JSON.stringify({ result: { mimeType: 'image/png', data: 'pixels', imageSize: { width: 10, height: 10 } } }));
    else if (body.method === 'click') { res.statusCode = 400; res.end(JSON.stringify({ error: 'Disabled' })); }
    else res.end(JSON.stringify({ result: { enabled: false } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const env = { GRAFF_DESKTOP_ENDPOINT: `http://127.0.0.1:${server.address().port}`, GRAFF_DESKTOP_SECRET: 'test', GRAFF_DESKTOP_CHAT: 'page:7' };
  try {
    await callTool('browser', { action: 'tabs' }, env);
    assert.equal(requests[0].body.chat, 'page:7'); assert.equal(requests[0].token, 'Bearer test');
    const image = await callTool('browser', { action: 'screenshot' }, env);
    assert.equal(requests[1].url, '/command'); assert.equal(image.content[0].type, 'image');
    assert.match(image.content[1].text, /imageSize/);
    await assert.rejects(callTool('browser', { action: 'click', selector: '#x' }, env), /Disabled/);
    // Codegraff has no computer use: the tool is not in the catalog and never reaches the app.
    await assert.rejects(callTool('computer', { action: 'status' }, env), /Unknown desktop tool/);
    assert.equal(requests.length, 3);
    assert.deepEqual(tools.map(t => t.name), ['create_html', 'profiler', 'browser']);
  } finally { server.close(); }
});
