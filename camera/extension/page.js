// Ponte Camera, page script (the Meet page's own world, before Meet's scripts run).
// Wraps navigator.mediaDevices.getUserMedia: a camera track Meet asks for is replaced by a track whose frames are
// drawn through a WebGL2 shader with the numbers bridge.js hands over (the colour matrix, the shadow lift and the
// part of the frame shown, all from Specs/camera_rules.t27). Audio tracks pass untouched. When nothing changes the
// picture (needs is false) a frame passes as it came. The shader computes cm_apply_pixel's steps in its order.
(() => {
  const TAG = '__ponteCamera';
  const md = navigator.mediaDevices;
  if (!md || typeof md.getUserMedia !== 'function') return;
  if (typeof MediaStreamTrackProcessor !== 'function' || typeof MediaStreamTrackGenerator !== 'function') return;

  let params = null;            // { needs, m: [13], crop: [4] }
  let active = 0;               // processed cameras on this page
  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data || event.data[TAG] !== 'params') return;
    params = event.data.p || null;
  });
  window.postMessage({ [TAG]: 'ready' }, '*');
  const report = () => window.postMessage({ [TAG]: 'status', cameras: active }, '*');

  const VERTEX = `#version 300 es
    in vec2 a_pos;
    out vec2 v_uv;
    void main() {
      // Output (x, y) from the top left in 0...1, as cm_crop's coordinates.
      v_uv = vec2((a_pos.x + 1.0) * 0.5, (1.0 - a_pos.y) * 0.5);
      gl_Position = vec4(a_pos, 0.0, 1.0);
    }`;
  const FRAGMENT = `#version 300 es
    precision highp float;
    uniform sampler2D u_tex;
    uniform vec3 u_r0; uniform vec3 u_r1; uniform vec3 u_r2;   // the matrix rows (cm_color_params 0...8)
    uniform vec3 u_off;                                         // the offsets (9...11)
    uniform float u_k;                                          // the shadow lift (12)
    uniform vec4 u_crop;                                        // u0, v0, du, dv (cm_crop)
    in vec2 v_uv;
    out vec4 o_color;
    void main() {
      vec3 c = texture(u_tex, u_crop.xy + v_uv * u_crop.zw).rgb;
      vec3 v = clamp(vec3(dot(u_r0, c), dot(u_r1, c), dot(u_r2, c)) + u_off, 0.0, 1.0);
      vec3 d = 1.0 - v;
      o_color = vec4(clamp(v + u_k * v * d * d, 0.0, 1.0), 1.0);
    }`;

  // One drawing context per processed camera.
  function makeRenderer() {
    const canvas = new OffscreenCanvas(2, 2);
    const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: false,
                                             preserveDrawingBuffer: false, desynchronized: true });
    if (!gl) return null;
    const compile = (type, source) => {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
      return shader;
    };
    const program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const pos = gl.getAttribLocation(program, 'a_pos');
    gl.enableVertexAttribArray(pos);
    gl.vertexAttribPointer(pos, 2, gl.FLOAT, false, 0, 0);
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const u = (name) => gl.getUniformLocation(program, name);
    const loc = { r0: u('u_r0'), r1: u('u_r1'), r2: u('u_r2'), off: u('u_off'), k: u('u_k'), crop: u('u_crop'),
                  tex: u('u_tex') };
    gl.uniform1i(loc.tex, 0);

    return (frame, p) => {
      const w = frame.displayWidth, h = frame.displayHeight;
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      gl.viewport(0, 0, w, h);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
      const m = p.m;
      gl.uniform3f(loc.r0, m[0], m[1], m[2]);
      gl.uniform3f(loc.r1, m[3], m[4], m[5]);
      gl.uniform3f(loc.r2, m[6], m[7], m[8]);
      gl.uniform3f(loc.off, m[9], m[10], m[11]);
      gl.uniform1f(loc.k, m[12]);
      gl.uniform4f(loc.crop, p.crop[0], p.crop[1], p.crop[2], p.crop[3]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      return new VideoFrame(canvas, { timestamp: frame.timestamp, duration: frame.duration ?? undefined });
    };
  }

  function processTrack(source) {
    const generator = new MediaStreamTrackGenerator({ kind: 'video' });
    const reader = new MediaStreamTrackProcessor({ track: source }).readable.getReader();
    const writer = generator.writable.getWriter();
    let render = null;
    let failed = false;
    let running = true;
    active += 1;
    report();
    const finish = () => {
      if (!running) return;
      running = false;
      active = Math.max(0, active - 1);
      report();
    };
    (async () => {
      try {
        for (;;) {
          const { value: frame, done } = await reader.read();
          if (done) break;
          const p = params;
          if (!p || !p.needs || failed) {
            await writer.write(frame);
            continue;
          }
          try {
            if (!render) render = makeRenderer();
            if (!render) throw new Error('no WebGL2');
            const out = render(frame, p);
            frame.close();
            await writer.write(out);
          } catch (error) {
            // A drawing failure leaves the camera as it is rather than black.
            failed = true;
            console.warn('Ponte Camera: passing frames unchanged', error);
            try { await writer.write(frame); } catch { frame.close(); }
          }
        }
      } catch {
        // The track ended or Meet stopped it.
      } finally {
        finish();
        try { await writer.close(); } catch {}
      }
    })();

    // Meet sees the camera's own settings, constraints and label, and stopping the track stops the camera.
    for (const name of ['getSettings', 'getCapabilities', 'getConstraints']) {
      generator[name] = () => source[name]();
    }
    generator.applyConstraints = (c) => source.applyConstraints(c);
    Object.defineProperty(generator, 'label', { get: () => source.label });
    Object.defineProperty(generator, 'enabled', { get: () => source.enabled, set: (v) => { source.enabled = v; } });
    const stop = generator.stop.bind(generator);
    generator.stop = () => { stop(); source.stop(); finish(); };
    source.addEventListener('ended', () => { stop(); finish(); });
    return generator;
  }

  const original = md.getUserMedia.bind(md);
  md.getUserMedia = async function getUserMedia(constraints) {
    const stream = await original(constraints);
    if (!constraints || !constraints.video) return stream;
    try {
      const tracks = stream.getTracks().map((t) => (t.kind === 'video' ? processTrack(t) : t));
      return new MediaStream(tracks);
    } catch (error) {
      console.warn('Ponte Camera: camera left unchanged', error);
      return stream;
    }
  };
})();
