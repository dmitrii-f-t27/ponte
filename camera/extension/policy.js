// Ponte Camera: the decisions of Specs/camera_rules.t27, run as cm.wasm (the spec's C, built by camera/build-wasm.sh).
// Imported by the service worker (sw.js) and by the diagnostic page (camera/test/diagnose.html). Nothing is decided
// here: values go to the WebAssembly and back. The page script (page.js) cannot run WebAssembly in Meet's world, so
// buildPolicy evaluates the pipeline functions over their whole domains and the page looks the answers up.
// The numbers below are the spec's constants; camera/test/constants.mjs checks each against the generated C.

const SETTINGS = 9;          // CM_SET_COUNT
const TRK_COUNT = 6;         // CM_TRK_COUNT
const TEV_COUNT = 6;         // CM_TEV_COUNT
const RV_COUNT = 3;          // CM_RV_COUNT
const STAGE_COUNT = 8;       // CM_STAGE_COUNT
const RENDER_TRIES = 3;      // CM_RENDER_TRIES
const ERROR_RANKS = 3;       // CM_ERROR_RANK_COUNT
const POLICY_REV = 3;        // CM_POLICY_REV
const REPORT_NAME = 0;       // CM_REPORT_NAME
const REPORT_TEXT = 1;       // CM_REPORT_TEXT
const REPORT_NAME_MAX = 64;  // CM_REPORT_NAME_MAX
const REPORT_TEXT_MAX = 200; // CM_REPORT_TEXT_MAX

export async function loadRules(bytes) {
  const { instance } = await WebAssembly.instantiate(bytes, {});
  instance.exports._initialize?.();
  return instance.exports;
}

const flag = (b) => (b ? 1 : 0);

// Settings as the spec holds them, and the numbers the shader needs.
export function decide(x, on, values) {
  const s = [];
  for (let k = 0; k < SETTINGS; k++) {
    const v = Number.isFinite(values?.[k]) ? Math.trunc(values[k]) : Number(x.cm_setting_default(BigInt(k)));
    s.push(Number(x.cm_clamp_setting(BigInt(k), BigInt(Math.max(-1e9, Math.min(1e9, v))))));
  }
  const b = s.map(BigInt);
  const floats = () => new Float32Array(x.memory.buffer, x.cm_wasm_floats(), 16);
  const n = Number(x.cm_color_params(b[0], b[1], b[2], b[3], b[4], x.cm_wasm_floats()));
  const params = Array.from(floats().slice(0, n));
  x.cm_crop(b[5], b[6], b[7], b[8], x.cm_wasm_floats());
  const crop = Array.from(floats().slice(0, 4));
  const colorIdentity = x.cm_color_identity(b[0], b[1], b[2], b[3], b[4]) !== 0;
  const frameIdentity = x.cm_frame_identity(b[5], b[6], b[7], b[8]) !== 0;
  const needs = x.cm_needs_processing(flag(on), flag(colorIdentity), flag(frameIdentity)) !== 0;
  return { on: !!on, s, params, crop, needs, colorIdentity, policy: buildPolicy(x) };
}

// The pipeline's tables (see page.js for how they are indexed).
export function buildPolicy(x) {
  const route = [];
  for (let state = 0; state < TRK_COUNT; state++) {
    for (let needs = 0; needs < 2; needs++) {
      for (let due = 0; due < 2; due++) {
        for (let sized = 0; sized < 2; sized++) {
          route.push(Number(x.cm_trk_route(BigInt(state), needs, due, sized)));
        }
      }
    }
  }
  const stepState = [], stepAction = [];
  for (let state = 0; state < TRK_COUNT; state++) {
    for (let event = 0; event < TEV_COUNT; event++) {
      for (let usable = 0; usable < 2; usable++) {
        stepState.push(Number(x.cm_trk_step_state(BigInt(state), BigInt(event), usable)));
        stepAction.push(Number(x.cm_trk_step_action(BigInt(state), BigInt(event), usable)));
      }
    }
  }
  const failVariant = [], failFails = [], failRetry = [], failState = [];
  for (let variant = 0; variant < RV_COUNT; variant++) {
    for (let fails = 0; fails < RENDER_TRIES; fails++) {
      for (let stage = 0; stage < STAGE_COUNT; stage++) {
        for (let proven = 0; proven < 2; proven++) {
          for (let ci = 0; ci < 2; ci++) {
            const a = [BigInt(variant), BigInt(fails), BigInt(stage), proven, ci];
            failVariant.push(Number(x.cm_render_next_variant(...a)));
            failFails.push(Number(x.cm_render_next_fails(...a)));
            failRetry.push(Number(x.cm_render_retry_ms(...a)));
            failState.push(Number(x.cm_render_next_state(...a)));
          }
        }
      }
    }
  }
  const usable = [];
  for (let variant = 0; variant < RV_COUNT; variant++) {
    for (let ci = 0; ci < 2; ci++) usable.push(x.cm_render_usable(BigInt(variant), ci) !== 0 ? 1 : 0);
  }
  // The first renderer by the one that last drew (-1: none yet).
  const first = [];
  for (let lastGood = -1; lastGood < RV_COUNT; lastGood++) {
    for (let ci = 0; ci < 2; ci++) first.push(Number(x.cm_render_first(BigInt(lastGood), ci)));
  }
  const bucket = [];
  for (let state = 0; state < TRK_COUNT; state++) bucket.push(Number(x.cm_trk_bucket(BigInt(state))));
  const errorRank = [];
  for (let has = 0; has < 2; has++) for (let troubled = 0; troubled < 2; troubled++) {
    errorRank.push(Number(x.cm_report_error_rank(has, troubled)));
  }
  // Whether a report of one rank takes the place of the best so far, by (rank, best, newer).
  const errorTakes = [];
  for (let rank = 0; rank < ERROR_RANKS; rank++) for (let best = 0; best < ERROR_RANKS; best++) {
    for (let newer = 0; newer < 2; newer++) errorTakes.push(x.cm_report_error_takes(BigInt(rank), BigInt(best), newer) !== 0 ? 1 : 0);
  }
  return {
    rev: POLICY_REV, trk: TRK_COUNT, tev: TEV_COUNT, rv: RV_COUNT, stages: STAGE_COUNT, tries: RENDER_TRIES,
    ranks: ERROR_RANKS, nameMax: REPORT_NAME_MAX, textMax: REPORT_TEXT_MAX,
    route, stepState, stepAction, failVariant, failFails, failRetry, failState, usable, first, bucket, errorRank,
    errorTakes,
  };
}

// --- The link to Ponte -----------------------------------------------------------------------------------------------
export const dialWaitMs = (x, reason, msSince, failures, pages) =>
  Number(x.cm_dial_wait_ms(BigInt(reason), BigInt(Math.trunc(msSince)), BigInt(failures), BigInt(pages)));
export const dialFailuresAfter = (x, failures, opened) => Number(x.cm_dial_failures_after(BigInt(failures), flag(opened)));
export const linkCameras = (x, n) => Number(x.cm_link_cameras(BigInt(Math.trunc(Number(n) || 0))));
// A link message of this protocol version is read (no integer version: not read).
export const linkVersionTaken = (x, v) => Number.isSafeInteger(v) && x.cm_link_version_taken(BigInt(v)) !== 0;
// How much a page's error counts when one of several is reported (0: none).
export const errorRank = (x, hasError, troubled) => Number(x.cm_report_error_rank(flag(hasError), flag(troubled)));
// Whether a report of `rank` takes the place of the best so far (`best`); among equals only a `newer` one.
export const errorTakes = (x, rank, best, newer) =>
  x.cm_report_error_takes(BigInt(Math.trunc(rank)), BigInt(Math.trunc(best)), flag(newer)) !== 0;

// --- The pages' reports ------------------------------------------------------------------------------------------------
// How long a page's report, msSince old, is still good (0: the page is gone).
export const pageLeaseLeftMs = (x, msSince) => Number(x.cm_page_lease_left_ms(BigInt(Math.trunc(Number(msSince) || 0))));
// A page said it is gone (pagehide): whether the tab's report is forgotten.
export const pageGoneForgets = (x, hasReport, sameDocument, reportHasDocument) =>
  x.cm_page_gone_forgets(flag(hasReport), flag(sameDocument), flag(reportHasDocument)) !== 0;

// A text a page reported, cleaned by the spec (printable ASCII, at most the limit of its kind).
function clean(x, text, kind) {
  const bytes = new TextEncoder().encode(String(text ?? '')).subarray(0, 256);
  const buffer = new Uint8Array(x.memory.buffer, x.cm_wasm_bytes(), 256);
  buffer.set(bytes);
  const n = Number(x.cm_report_clean(x.cm_wasm_bytes(), BigInt(bytes.length), BigInt(kind)));
  return new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.cm_wasm_bytes(), n));
}

// The error a page reported, as it goes to Ponte: a known stage, the name and the message cleaned; null for none.
export function cleanError(x, error) {
  if (!error || typeof error !== 'object') return null;
  return {
    stage: Number(x.cm_report_stage(BigInt(Math.trunc(Number(error.stage) || 0)))),
    renderer: Number(x.cm_render_variant_held(BigInt(Math.trunc(Number(error.renderer) || 0)))),
    name: clean(x, error.name, REPORT_NAME),
    message: clean(x, error.message, REPORT_TEXT),
  };
}
