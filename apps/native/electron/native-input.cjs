// Test-only native macOS input for the GUI suites: real OS clicks, typing,
// Accessibility snapshots and display capture against Codegraff's own window.
// Not an agent tool and not reachable from the app: Codegraff has no computer
// use. Permissions are only read here, never requested.
const { desktopCapturer, screen } = require('electron');
const path = require('node:path');

class NativeInput {
  constructor(resources) { this.resources = resources; }
  native(method, params = {}) {
    if (process.platform !== 'darwin') throw new Error('Native input tests run on macOS only');
    const result = JSON.parse(require(path.join(this.resources, 'native/activity.node')).computer(JSON.stringify({ ...params, method })));
    if (result.error) throw new Error(result.error);
    return result;
  }
  status() {
    if (process.platform !== 'darwin') return { platform: process.platform, accessibility: false, screenRecording: false };
    return { platform: process.platform, ...this.native('permissions') };
  }
  async command(method, params = {}) {
    if (method === 'screenshot') {
      const display = screen.getPrimaryDisplay();
      const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 1600, height: 1000 } });
      const source = sources.find(s => s.display_id === String(display.id));
      if (!source || source.thumbnail.isEmpty()) throw new Error('Display capture is unavailable');
      return { mimeType: 'image/png', data: source.thumbnail.toPNG().toString('base64'), bounds: display.bounds, imageSize: source.thumbnail.getSize() };
    }
    if (!['apps', 'snapshot', 'click', 'type', 'key'].includes(method)) throw new Error(`Unsupported native input action: ${method}`);
    return this.native(method, params);
  }
}
module.exports = { NativeInput };
