// Ponte Camera, page script (the Meet page's own world, before Meet's scripts run).
// Wraps navigator.mediaDevices.getUserMedia: a camera track Meet asks for is replaced by a track whose frames are
// drawn through a renderer with the numbers bridge.js hands over (the colour matrix, the shadow lift and the part of
// the frame shown, all from Specs/camera_rules.t27). Audio tracks pass untouched. Every decision about a frame (pass
// or draw, which renderer, what a failure does, when to try again, what the page reports) is a lookup in the tables
// the service worker built from the spec (policy.js); this script carries the answers out with the browser's APIs.
// Frame ownership: a frame read from the camera is this script's until it is handed to Meet's writer (the writer
// takes it) or closed; it is closed only after a drawn copy exists, so a failed draw still hands Meet the live
// original, and a frame is never handed over after it was closed. The WebGL shader computes cm_apply_pixel's steps
// in its order.
(() => {
  const TAG = '__ponteCamera';
  const md = navigator.mediaDevices;
  if (!md || typeof md.getUserMedia !== 'function') return;
  if (typeof MediaStreamTrackProcessor !== 'function' || typeof MediaStreamTrackGenerator !== 'function') return;

  // Codes of Specs/camera_rules.t27 (camera/test/constants.mjs checks each against the generated C).
  const TRK_STARTING = 0;        // CM_TRK_STARTING
  const TRK_ENDED = 5;           // CM_TRK_ENDED
  const TEV_PASSED = 0;          // CM_TEV_PASSED
  const TEV_HELD = 1;            // CM_TEV_HELD
  const TEV_DRAWN = 2;           // CM_TEV_DRAWN
  const TEV_WRITE_FAILED = 3;    // CM_TEV_WRITE_FAILED
  const TEV_STOPPED = 4;         // CM_TEV_STOPPED
  const TEV_SETTINGS = 5;        // CM_TEV_SETTINGS
  const TACT_CLEAR = 1;          // CM_TACT_CLEAR
  const TACT_RESET = 2;          // CM_TACT_RESET
  const TACT_CLOSE = 3;          // CM_TACT_CLOSE
  const ROUTE_DRAW = 1;          // CM_ROUTE_DRAW
  const ROUTE_STOP = 2;          // CM_ROUTE_STOP
  const RV_FIRST = 1;            // CM_RV_FIRST
  const RV_WEBGL_BITMAP = 0;     // CM_RV_WEBGL_BITMAP
  const RV_WEBGL_CANVAS = 1;     // CM_RV_WEBGL_CANVAS
  const RV_CANVAS2D = 2;         // CM_RV_CANVAS2D
  const STAGE_NONE = 0;          // CM_STAGE_NONE
  const STAGE_CREATE = 1;        // CM_STAGE_CREATE
  const STAGE_UPLOAD = 2;        // CM_STAGE_UPLOAD
  const STAGE_DRAW = 3;          // CM_STAGE_DRAW
  const STAGE_OUTPUT = 4;        // CM_STAGE_OUTPUT
  const STAGE_LOST = 5;          // CM_STAGE_LOST
  const STAGE_WRITE = 6;         // CM_STAGE_WRITE
  const STAGE_READ = 7;          // CM_STAGE_READ
  const BUCKET_PASSING = 1;      // CM_BUCKET_PASSING
  const BUCKET_PROCESSED = 2;    // CM_BUCKET_PROCESSED
  const BUCKET_TROUBLE = 3;      // CM_BUCKET_TROUBLE
  const POLICY_REV = 3;          // CM_POLICY_REV
  const REPORT_NAME_MAX = 64;    // CM_REPORT_NAME_MAX
  const REPORT_TEXT_MAX = 200;   // CM_REPORT_TEXT_MAX
  // Names for the console, by CM_STAGE_* and CM_RV_*.
  const STAGE_NAMES = ['an unknown step', 'making the context', 'taking the frame in', 'drawing', 'making the new frame',
    'a lost context', "Meet's track", 'reading the camera'];
  const RENDERER_NAMES = { [RV_WEBGL_BITMAP]: 'WebGL2 (bitmap)', [RV_WEBGL_CANVAS]: 'WebGL2 (canvas)',
    [RV_CANVAS2D]: '2D canvas' };

  let params = null;             // { needs, colorIdentity, m: [13], crop: [4] }
  let policy = null;             // the pipeline's tables (policy.js buildPolicy)
  let pageError = null;          // the last write or read failure of an ended track on this page
  const tracks = new Set();
  const proven = new Set();      // the renderers that drew a frame on this page
  let lastGood = -1;             // the renderer that drew last on this page (-1: none yet)

  // The tables as the service worker built them for this version (else none: every frame passes as it came).
  function usablePolicy(p) {
    if (!p || p.rev !== POLICY_REV) return null;
    const fail = p.rv * p.tries * p.stages * 4;
    const sizes = [[p.route, p.trk * 8], [p.stepState, p.trk * p.tev * 2], [p.stepAction, p.trk * p.tev * 2],
      [p.failVariant, fail], [p.failFails, fail], [p.failRetry, fail], [p.failState, fail],
      [p.usable, p.rv * 2], [p.first, (p.rv + 1) * 2], [p.bucket, p.trk], [p.errorRank, 4],
      [p.errorTakes, p.ranks * p.ranks * 2]];
    return sizes.every(([a, n]) => Array.isArray(a) && a.length === n) ? p : null;
  }

  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data) return;
    // A report on request (the diagnostic page reads the drawn counts; reports otherwise go out on changes only).
    if (event.data[TAG] === 'query') { report(); return; }
    if (event.data[TAG] !== 'params') return;
    const p = event.data.p || null;
    const changed = JSON.stringify(p) !== JSON.stringify(params);
    params = p;
    policy = usablePolicy(event.data.policy);
    if (changed) for (const t of tracks) step(t, TEV_SETTINGS);
  });
  window.postMessage({ [TAG]: 'ready' }, '*');

  const bucket = (t) => (policy ? policy.bucket[t.state] : BUCKET_PASSING);
  const colorKept = () => (params && params.colorIdentity ? 1 : 0);
  // The renderer a track starts with (cm_render_first: the one that last drew on this page, if it can show the
  // settings).
  const firstRenderer = () => (policy ? policy.first[(lastGood + 1) * 2 + colorKept()] : RV_FIRST);

  // The page's report: cameras by bucket, the error of the highest rank (cm_report_error_rank: a camera in trouble
  // before one that is not, the last ended track's counting as not in trouble; cm_report_error_takes without times:
  // the first among equals), and each track's state for the diagnostic page.
  function report() {
    const n = { processed: 0, passing: 0, troubled: 0 };
    const rank = (error, troubled) => (policy ? policy.errorRank[(error ? 2 : 0) + (troubled ? 1 : 0)] : 0);
    const takes = (r, b) => (policy ? policy.errorTakes[(r * policy.ranks + b) * 2] === 1 : false);
    let error = null, best = 0;
    const consider = (e, troubled) => {
      const r = rank(e, troubled);
      if (takes(r, best)) { best = r; error = e; }
    };
    for (const t of tracks) {
      const b = bucket(t);
      if (b === BUCKET_PROCESSED) n.processed += 1;
      else if (b === BUCKET_PASSING) n.passing += 1;
      else if (b === BUCKET_TROUBLE) n.troubled += 1;
      consider(t.error, b === BUCKET_TROUBLE);
    }
    consider(pageError, false);
    const detail = Array.from(tracks, (t) => ({ state: t.state, renderer: t.variant, fails: t.fails, drawn: t.drawn }));
    window.postMessage({ [TAG]: 'status', ...n, error, detail }, '*');
  }

  // A failure's stage travels with it.
  class Staged {
    constructor(stage, cause) { this.stage = stage; this.cause = cause; }
  }
  const at = (stage, fn) => {
    try { return fn(); } catch (error) { throw error instanceof Staged ? error : new Staged(stage, error); }
  };

  // Keeps the failure for the report and says it in the console readably (never "[object ...]"): a failure the
  // same as the track's last one (stage, renderer, name, message) is not said again.
  function remember(t, stage, cause) {
    const name = String(cause?.name ?? typeof cause).slice(0, REPORT_NAME_MAX);
    const message = String(cause?.message ?? cause).slice(0, REPORT_TEXT_MAX);
    t.error = { stage, renderer: t.variant, name, message };
    const key = `${stage} ${t.variant} ${name} ${message}`;
    if (t.warned === key) return;
    t.warned = key;
    const where = stage === STAGE_WRITE || stage === STAGE_READ ? STAGE_NAMES[stage]
      : `${RENDERER_NAMES[t.variant] ?? 'renderer'}, ${STAGE_NAMES[stage] ?? STAGE_NAMES[STAGE_NONE]}`;
    console.warn(`Ponte Camera: failed at ${where}: ${name}: ${message}`);
  }

  // --- Renderers (CM_RV_*) ------------------------------------------------------------------------------------------
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

  // The new frame keeps the camera frame's time.
  function output(canvas, frame, fromCanvas) {
    const init = { timestamp: frame.timestamp, alpha: 'discard' };
    if (frame.duration != null) init.duration = frame.duration;
    if (fromCanvas) return new VideoFrame(canvas, init);
    const bitmap = canvas.transferToImageBitmap();
    try { return new VideoFrame(bitmap, init); } finally { bitmap.close(); }
  }

  function webglRenderer(fromCanvas) {
    let lost = false;
    const canvas = at(STAGE_CREATE, () => new OffscreenCanvas(2, 2));
    canvas.addEventListener('webglcontextlost', () => { lost = true; });
    const gl = at(STAGE_CREATE, () => canvas.getContext('webgl2', { alpha: false, antialias: false, depth: false,
      stencil: false, premultipliedAlpha: false, preserveDrawingBuffer: fromCanvas, desynchronized: false }));
    if (!gl) throw new Staged(STAGE_CREATE, new Error('no WebGL2 context'));
    const own = at(STAGE_CREATE, () => {
      const shaders = [];
      const compile = (type, source) => {
        const shader = gl.createShader(type);
        shaders.push(shader);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader) || 'shader');
        return shader;
      };
      const program = gl.createProgram();
      gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX));
      gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT));
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) || 'program');
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
      const loc = { r0: u('u_r0'), r1: u('u_r1'), r2: u('u_r2'), off: u('u_off'), k: u('u_k'), crop: u('u_crop') };
      gl.uniform1i(u('u_tex'), 0);
      return { shaders, program, buffer, texture, loc };
    });
    let checked = false;
    const isLost = () => lost || gl.isContextLost();
    return {
      draw(frame, p) {
        if (isLost()) throw new Staged(STAGE_LOST, new Error('the WebGL context was lost'));
        const w = frame.displayWidth, h = frame.displayHeight;
        if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
        at(STAGE_UPLOAD, () => {
          gl.viewport(0, 0, w, h);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
        });
        at(STAGE_DRAW, () => {
          const m = p.m, loc = own.loc;
          gl.uniform3f(loc.r0, m[0], m[1], m[2]);
          gl.uniform3f(loc.r1, m[3], m[4], m[5]);
          gl.uniform3f(loc.r2, m[6], m[7], m[8]);
          gl.uniform3f(loc.off, m[9], m[10], m[11]);
          gl.uniform1f(loc.k, m[12]);
          gl.uniform4f(loc.crop, p.crop[0], p.crop[1], p.crop[2], p.crop[3]);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
        });
        if (!checked) {
          // Once per renderer (getError waits for the GPU): an error no call threw, such as a frame it could not take.
          const code = gl.getError();
          if (code !== gl.NO_ERROR) {
            throw new Staged(isLost() ? STAGE_LOST : STAGE_DRAW, new Error(`WebGL error 0x${code.toString(16)}`));
          }
          checked = true;
        }
        const out = at(STAGE_OUTPUT, () => output(canvas, frame, fromCanvas));
        if (isLost()) {
          // Lost while drawing: the new frame may be empty, so it is not handed to Meet.
          out.close();
          throw new Staged(STAGE_LOST, new Error('the WebGL context was lost while drawing'));
        }
        return out;
      },
      dispose() {
        try {
          gl.deleteTexture(own.texture);
          gl.deleteBuffer(own.buffer);
          gl.deleteProgram(own.program);
          for (const shader of own.shaders) gl.deleteShader(shader);
        } catch {}
        // Gives the context back at once rather than when the canvas is collected (Chrome keeps only a few).
        try { gl.getExtension('WEBGL_lose_context')?.loseContext(); } catch {}
      },
    };
  }

  // Only the part of the frame shown (zoom, pan, mirror: cm_crop's numbers, a negative du drawn flipped).
  function canvas2dRenderer() {
    const canvas = at(STAGE_CREATE, () => new OffscreenCanvas(2, 2));
    const ctx = at(STAGE_CREATE, () => canvas.getContext('2d', { alpha: false }));
    if (!ctx) throw new Staged(STAGE_CREATE, new Error('no 2D context'));
    return {
      draw(frame, p) {
        const w = frame.displayWidth, h = frame.displayHeight;
        if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
        const [u0, v0, du, dv] = p.crop;
        at(STAGE_UPLOAD, () => {
          ctx.setTransform(du < 0 ? -1 : 1, 0, 0, 1, du < 0 ? w : 0, 0);
          ctx.drawImage(frame, (du < 0 ? u0 + du : u0) * w, v0 * h, Math.abs(du) * w, dv * h, 0, 0, w, h);
        });
        return at(STAGE_OUTPUT, () => output(canvas, frame, false));
      },
      dispose() { canvas.width = 1; canvas.height = 1; },
    };
  }

  function makeRenderer(variant) {
    if (variant === RV_CANVAS2D) return canvas2dRenderer();
    if (variant === RV_WEBGL_BITMAP) return webglRenderer(false);
    return webglRenderer(true);
  }

  // --- One wrapped camera track -------------------------------------------------------------------------------------
  function release(t) {
    if (!t.renderer) return;
    try { t.renderer.dispose(); } catch {}
    t.renderer = null;
  }

  // CM_TACT_CLOSE, and the end of the read loop: everything this track owns is released once.
  function close(t) {
    if (t.closed) return;
    t.closed = true;
    release(t);
    t.stopTracks();
    t.reader.cancel().catch(() => {});
    t.writer.close().catch(() => {});
    tracks.delete(t);
    report();
  }

  function step(t, event) {
    const p = policy;
    if (!p) return;
    const before = bucket(t);
    const i = (t.state * p.tev + event) * 2 + p.usable[t.variant * 2 + colorKept()];
    t.state = p.stepState[i];
    const action = p.stepAction[i];
    if (action === TACT_CLEAR) { t.fails = 0; t.error = null; }
    if (action === TACT_RESET) { release(t); t.variant = firstRenderer(); t.fails = 0; t.retryAt = 0; }
    if (action === TACT_CLOSE) close(t);
    if (bucket(t) === BUCKET_PROCESSED) pageError = null;
    if (bucket(t) !== before) report();
  }

  // A renderer failed: it is released (the spec's rule for every failure), the failure tables say what comes next
  // (by whether it ever drew on this page).
  function failed(t, error) {
    const p = policy;
    const stage = error instanceof Staged ? error.stage : STAGE_NONE;
    remember(t, stage, error instanceof Staged ? error.cause : error);
    release(t);
    const i = (((t.variant * p.tries + t.fails) * p.stages + stage) * 2 + (proven.has(t.variant) ? 1 : 0)) * 2 +
      colorKept();
    t.variant = p.failVariant[i];
    t.fails = p.failFails[i];
    t.retryAt = performance.now() + p.failRetry[i];
    t.state = p.failState[i];
    report();
  }

  // Hands a frame to Meet. The writer takes it; a refused frame is still this script's and is closed here.
  // Returns whether the track goes on.
  async function write(t, frame) {
    try {
      await t.writer.write(frame);
      return true;
    } catch (error) {
      frame.close();
      if (!t.stopping) {
        remember(t, STAGE_WRITE, error);
        pageError = t.error;
      }
      step(t, t.stopping ? TEV_STOPPED : TEV_WRITE_FAILED);
      return false;
    }
  }

  // One camera frame. Returns whether the track goes on.
  async function handle(t, frame) {
    const p = policy;
    if (!p) return write(t, frame);
    const needs = params && params.needs ? 1 : 0;
    const due = performance.now() >= t.retryAt ? 1 : 0;
    const sized = frame.displayWidth > 0 && frame.displayHeight > 0 ? 1 : 0;
    const route = p.route[((t.state * 2 + needs) * 2 + due) * 2 + sized];
    if (route === ROUTE_STOP) {
      frame.close();
      return false;
    }
    if (route !== ROUTE_DRAW) {
      if (!(await write(t, frame))) return false;
      step(t, needs ? TEV_HELD : TEV_PASSED);
      return true;
    }
    let out;
    try {
      if (!t.renderer) t.renderer = makeRenderer(t.variant);
      out = t.renderer.draw(frame, params);
    } catch (error) {
      failed(t, error);
      // The original is still open and still this script's: Meet gets the live picture, unprocessed.
      return write(t, frame);
    }
    frame.close();
    if (!(await write(t, out))) return false;
    t.drawn += 1;
    proven.add(t.variant);
    lastGood = t.variant;
    step(t, TEV_DRAWN);
    return true;
  }

  function processTrack(source) {
    const generator = new MediaStreamTrackGenerator({ kind: 'video' });
    const stopGenerator = generator.stop.bind(generator);
    const t = {
      state: TRK_STARTING, variant: firstRenderer(), fails: 0, retryAt: 0, drawn: 0, renderer: null, error: null,
      warned: '',
      stopping: false, closed: false,
      reader: new MediaStreamTrackProcessor({ track: source }).readable.getReader(),
      writer: generator.writable.getWriter(),
      // Only this wrapper's own tracks: the camera track it asked for and the track it gave Meet.
      stopTracks: () => {
        try { stopGenerator(); } catch {}
        try { source.stop(); } catch {}
      },
    };
    tracks.add(t);
    report();
    (async () => {
      try {
        for (;;) {
          const { value: frame, done } = await t.reader.read();
          if (done) break;
          if (!(await handle(t, frame))) break;
        }
      } catch (error) {
        if (!t.stopping) {
          remember(t, STAGE_READ, error);
          pageError = t.error;
        }
      } finally {
        if (t.state !== TRK_ENDED) step(t, TEV_STOPPED);
        close(t);
      }
    })();

    // Meet sees the camera's own settings, constraints and label, and stopping the track stops the camera.
    for (const name of ['getSettings', 'getCapabilities', 'getConstraints']) {
      generator[name] = () => source[name]();
    }
    generator.applyConstraints = (c) => source.applyConstraints(c);
    Object.defineProperty(generator, 'label', { get: () => source.label });
    Object.defineProperty(generator, 'enabled', { get: () => source.enabled, set: (v) => { source.enabled = v; } });
    generator.stop = () => {
      t.stopping = true;
      t.stopTracks();
    };
    source.addEventListener('ended', () => {
      t.stopping = true;
      try { stopGenerator(); } catch {}
    });
    return generator;
  }

  const original = md.getUserMedia.bind(md);
  md.getUserMedia = async function getUserMedia(constraints) {
    const stream = await original(constraints);
    if (!constraints || !constraints.video) return stream;
    try {
      const wrapped = stream.getTracks().map((track) => (track.kind === 'video' ? processTrack(track) : track));
      return new MediaStream(wrapped);
    } catch (error) {
      console.warn(`Ponte Camera: camera left unchanged: ${error?.name ?? 'Error'}: ${error?.message ?? error}`);
      return stream;
    }
  };
})();
