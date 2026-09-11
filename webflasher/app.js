/**
 * DSGV web flasher — UI orchestration.
 *
 * Holds no rules of its own. Pin validity comes from catalog/chips.json
 * (generated from the firmware), device shape from catalog/devices.json, and
 * flash offsets from manifest.json (generated from each build's flash_args).
 * Anything hardcoded here would be a fourth place for those to disagree.
 */

import {
  checkPin, selectablePins, validateAssignments, buildProvisioningPayload,
  roleKey, familyFromChipName, comparePins,
} from './lib/config-builder.js';
import {
  DeviceSession, fetchBuildParts, serialSupported, unsupportedReason,
} from './lib/flasher.js';
import { MsgType } from './lib/dsgv-frame.js';

const CATALOG_DEVICES = '../catalog/devices.json';
const CATALOG_CHIPS   = '../catalog/chips.json';
const MANIFEST        = './firmware/manifest.json';

const $ = (id) => document.getElementById(id);

const state = {
  devices: null,
  chips: null,
  manifest: null,
  family: null,          // catalogue key, e.g. "ESP32-C3"
  device: null,
  assignments: {},       // roleKey -> pin
  session: null,
};

// ── Small view helpers ───────────────────────────────────────────────────────

function message(el, kind, text, items = []) {
  if (!text) { el.innerHTML = ''; return; }
  const list = items.length
    ? `<ul>${items.map((i) => `<li>${escape(i)}</li>`).join('')}</ul>` : '';
  el.innerHTML = `<div class="msg ${kind}">${escape(text)}${list}</div>`;
}

function escape(s) {
  return String(s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function log(line) {
  const el = $('log');
  el.hidden = false;
  el.textContent += `${line}\n`;
  el.scrollTop = el.scrollHeight;
}

// ── Load catalogue ───────────────────────────────────────────────────────────

async function loadJson(url, what) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`could not load ${what} (HTTP ${res.status})`);
  return res.json();
}

async function boot() {
  if (!serialSupported()) {
    $('step-unsupported').hidden = false;
    $('unsupported-reason').textContent = unsupportedReason();
    $('step-connect').hidden = true;
    return;
  }

  try {
    [state.devices, state.chips] = await Promise.all([
      loadJson(CATALOG_DEVICES, 'the device catalogue'),
      loadJson(CATALOG_CHIPS, 'the chip pin tables'),
    ]);
  } catch (err) {
    message($('connect-msg'), 'err', err.message);
    $('btn-connect').disabled = true;
    return;
  }

  $('btn-connect').addEventListener('click', onConnect);
  $('device-select').addEventListener('change', onDeviceChange);
  $('btn-flash').addEventListener('click', onFlash);
}

// ── 1. Connect ───────────────────────────────────────────────────────────────

async function onConnect() {
  const btn = $('btn-connect');
  btn.disabled = true;
  message($('connect-msg'), '', '');

  try {
    state.session = new DeviceSession(log);
    const reported = await state.session.connect();

    const family = familyFromChipName(state.chips, reported);
    if (!family) {
      await state.session.close();
      state.session = null;
      message($('connect-msg'), 'err',
        `This board reports "${reported}", which this flasher does not have `
        + `firmware for. Supported: ${Object.keys(state.chips.chips).join(', ')}.`);
      btn.disabled = false;
      return;
    }

    state.family = family;
    $('chip-badge').textContent = `${reported} → ${family}`;
    $('chip-badge').hidden = false;
    $('step-connect').classList.add('done');
    btn.textContent = 'Connected';

    populateDevices();
    $('step-device').hidden = false;
  } catch (err) {
    // A user dismissing the port picker is not an error worth shouting about.
    const dismissed = err?.name === 'NotFoundError';
    message($('connect-msg'), dismissed ? 'warn' : 'err',
      dismissed ? 'No port selected.' : `Could not connect: ${err.message}`);
    btn.disabled = false;
  }
}

// ── 2. Device ────────────────────────────────────────────────────────────────

function populateDevices() {
  const sel = $('device-select');
  sel.innerHTML = '<option value="">Select a device type…</option>';

  for (const d of state.devices.devices) {
    const opt = document.createElement('option');
    opt.value = d.id;
    opt.textContent = d.name;
    sel.append(opt);
  }
}

function onDeviceChange() {
  const id = $('device-select').value;
  state.device = state.devices.devices.find((d) => d.id === id) ?? null;
  state.assignments = {};

  $('device-desc').textContent = state.device?.description ?? '';
  $('step-pins').hidden = !state.device;
  $('step-flash').hidden = !state.device;

  if (state.device) buildPinForm();
}

// ── 3. Pins ──────────────────────────────────────────────────────────────────

function buildPinForm() {
  const chip = state.chips.chips[state.family];
  const grid = $('pin-grid');
  grid.innerHTML = '';

  for (const role of state.device.pin_roles) {
    const key = roleKey(role);
    const id = `pin-${key.replace(':', '-')}`;

    const wrap = document.createElement('div');
    const label = document.createElement('label');
    label.htmlFor = id;
    label.textContent = role.required ? role.label : `${role.label} (optional)`;

    const sel = document.createElement('select');
    sel.id = id;
    sel.dataset.roleKey = key;

    if (!role.required) {
      sel.append(new Option('Not fitted', '-1'));
    } else {
      sel.append(new Option('Select a pin…', ''));
    }

    // Only pins this chip can actually use for this direction are offered, so
    // a user cannot pick flash or a non-existent pin in the first place.
    for (const pin of selectablePins(chip, role.direction)) {
      const res = checkPin(chip, pin, role.direction);
      const suffix = role.direction === 'adc' ? ` (ADC1_CH${chip.adc1[pin]})`
                   : res.warning ? ' ⚠' : '';
      sel.append(new Option(`GPIO ${pin}${suffix}`, String(pin)));
    }

    const note = document.createElement('div');
    note.className = 'field-note';

    sel.addEventListener('change', () => {
      const v = sel.value === '' ? undefined : Number(sel.value);
      if (v === undefined) delete state.assignments[key];
      else state.assignments[key] = v;

      const res = v === undefined ? { ok: true } : checkPin(chip, v, role.direction);
      note.textContent = res.warning ?? '';
      note.classList.toggle('warn', Boolean(res.warning));
      revalidate();
    });

    wrap.append(label, sel, note);
    grid.append(wrap);
  }

  revalidate();
}

function revalidate() {
  const chip = state.chips.chips[state.family];
  const { errors, warnings } = validateAssignments(
    state.device, chip, state.assignments);

  const el = $('pin-msg');
  if (errors.length) {
    message(el, 'err', 'Fix these before flashing:', errors);
  } else if (warnings.length) {
    message(el, 'warn', 'These will work, but note:', warnings);
  } else {
    message(el, 'ok', 'Pin assignment looks good.');
  }

  $('btn-flash').disabled = errors.length > 0;
  return errors.length === 0;
}

// ── 4. Flash ─────────────────────────────────────────────────────────────────

async function onFlash() {
  if (!revalidate()) return;

  const btn = $('btn-flash');
  const status = $('flash-status');
  const bar = $('flash-progress');
  btn.disabled = true;
  message($('flash-msg'), '', '');

  try {
    if (!state.manifest) {
      status.textContent = 'loading manifest…';
      state.manifest = await loadJson(MANIFEST, 'the firmware manifest');
    }

    const build = state.manifest.builds.find((b) => b.chipFamily === state.family);
    if (!build) {
      throw new Error(
        `the manifest has no build for ${state.family}. `
        + `It contains: ${state.manifest.builds.map((b) => b.chipFamily).join(', ')}.`);
    }

    status.textContent = 'downloading firmware…';
    const parts = await fetchBuildParts(MANIFEST, build, (s) => { status.textContent = s; });
    log(`firmware: ${parts.map((p) => `${p.name} @ 0x${p.address.toString(16)}`).join(', ')}`);

    bar.hidden = false;
    status.textContent = 'writing flash — do not unplug';
    await state.session.flash(parts, (frac) => { bar.value = frac; });

    bar.hidden = true;
    status.textContent = 'device restarting…';
    await state.session.beginSerialSession();

    status.textContent = 'sending configuration…';
    const payload = buildProvisioningPayload(state.device, state.assignments);
    log(`config: ${JSON.stringify(payload)}`);

    const reply = await state.session.request(
      MsgType.SET_CONFIG, JSON.stringify(payload));

    // The device echoes what it actually accepted. Comparing is what turns
    // "probably fine" into "confirmed", and catches a pin the firmware refused
    // for a reason the browser's copy of the rules did not predict.
    const applied = JSON.parse(reply.text);
    log(`device confirmed: ${reply.text}`);

    const mismatches = comparePins(payload.pins, applied.pins);
    status.textContent = '';

    if (mismatches.length) {
      message($('flash-msg'), 'warn',
        'Flashed, but the device did not accept every pin:', mismatches);
    } else {
      message($('flash-msg'), 'ok',
        `Done. The board is now a ${state.device.name} and has restarted. `
        + 'Add it in the DSGV app to connect it to Wi-Fi.');
      $('step-flash').classList.add('done');
    }
  } catch (err) {
    bar.hidden = true;
    status.textContent = '';
    message($('flash-msg'), 'err', err.message);
    log(`error: ${err.stack ?? err.message}`);
    btn.disabled = false;
  }
}

boot();
