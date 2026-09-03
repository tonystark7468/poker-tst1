import { firebaseConfig } from "./firebase-config.js";
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth,
  onAuthStateChanged,
  signInAnonymously,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import {
  getFirestore,
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  collection,
  getDocs,
  onSnapshot,
  runTransaction,
  arrayUnion,
  Timestamp,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

// ---------------------------------------------------------------------
// Firebase setup
// ---------------------------------------------------------------------

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

function ensureSignedIn() {
  return new Promise((resolve, reject) => {
    const unsubscribe = onAuthStateChanged(
      auth,
      (user) => {
        if (user) {
          unsubscribe();
          resolve(user.uid);
        }
      },
      reject
    );
    signInAnonymously(auth).catch(reject);
  });
}

// ---------------------------------------------------------------------
// Game code
// ---------------------------------------------------------------------

const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no 0/O, 1/I/L
function generateCode(length = 5) {
  let code = "";
  for (let i = 0; i < length; i++) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return code;
}

// ---------------------------------------------------------------------
// Firestore refs
// ---------------------------------------------------------------------

const gameRef = (code) => doc(db, "games", code);
const playersRef = (code) => collection(db, "games", code, "players");
const playerRef = (code, uid) => doc(db, "games", code, "players", uid);

// ---------------------------------------------------------------------
// Game service — mirrors PokerTracker/Services/GameService.swift
// ---------------------------------------------------------------------

async function createGame(name, hostUid, hostName, defaultBuyIn, chipsPerDollar) {
  for (let i = 0; i < 8; i++) {
    const code = generateCode();
    const ref = gameRef(code);
    const snap = await getDoc(ref);
    if (snap.exists()) continue;

    const game = {
      code,
      name: name.trim() || "Poker Night",
      hostId: hostUid,
      status: "active",
      defaultBuyIn,
      createdAt: Timestamp.now(),
    };
    if (chipsPerDollar) game.chipsPerDollar = chipsPerDollar;
    await setDoc(ref, game);

    const player = {
      uid: hostUid,
      name: hostName,
      buyIns: [{ id: crypto.randomUUID(), amount: defaultBuyIn, timestamp: Timestamp.now() }],
      joinedAt: Timestamp.now(),
    };
    await setDoc(playerRef(code, hostUid), player);

    return game;
  }
  throw new Error("Couldn't generate a unique game code. Please try again.");
}

async function joinGame(code, uid, name) {
  const upperCode = code.trim().toUpperCase();
  const snap = await getDoc(gameRef(upperCode));
  if (!snap.exists()) {
    throw new Error("No game found with that code. Double-check and try again.");
  }
  const game = snap.data();
  if (game.status !== "active") {
    throw new Error("This game has already ended.");
  }

  const pRef = playerRef(upperCode, uid);
  const existing = await getDoc(pRef);
  if (!existing.exists()) {
    await setDoc(pRef, {
      uid,
      name,
      buyIns: [{ id: crypto.randomUUID(), amount: game.defaultBuyIn, timestamp: Timestamp.now() }],
      joinedAt: Timestamp.now(),
    });
  }
  return { ...game, code: upperCode };
}

// Host adds someone who doesn't have (or doesn't want to use) the app.
// Starts with no buy-in yet — the host records it as a separate step —
// which is what makes deletePlayer's "undo a mistake" window meaningful.
async function addManualPlayer(code, name, hostUid) {
  const id = `manual-${crypto.randomUUID()}`;
  await setDoc(playerRef(code, id), {
    uid: id,
    name,
    buyIns: [],
    joinedAt: Timestamp.now(),
    addedBy: hostUid,
  });
  return id;
}

// Only allowed (client-side and by the security rules) while the player
// has no buy-ins and hasn't cashed out — otherwise deleting them would
// silently erase real money from the settlement.
async function deletePlayer(code, uid) {
  await deleteDoc(playerRef(code, uid));
}

async function fetchGameWithPlayers(code) {
  const upperCode = code.toUpperCase();
  const snap = await getDoc(gameRef(upperCode));
  if (!snap.exists()) {
    throw new Error("No game found with that code.");
  }
  const game = { ...snap.data(), code: upperCode };
  const playersSnap = await getDocs(playersRef(upperCode));
  const players = playersSnap.docs.map((d) => ({ uid: d.id, ...d.data() }));
  return { game, players };
}

function listenToGame(code, onChange) {
  return onSnapshot(gameRef(code), (snap) => {
    onChange(snap.exists() ? { ...snap.data(), code } : null);
  });
}

function listenToPlayers(code, onChange) {
  return onSnapshot(playersRef(code), (snap) => {
    const players = snap.docs
      .map((d) => ({ uid: d.id, ...d.data() }))
      .sort((a, b) => (a.joinedAt?.toMillis() ?? 0) - (b.joinedAt?.toMillis() ?? 0));
    onChange(players);
  });
}

async function addBuyIn(code, uid, amount) {
  await updateDoc(playerRef(code, uid), {
    buyIns: arrayUnion({ id: crypto.randomUUID(), amount, timestamp: Timestamp.now() }),
  });
}

async function setCashOut(code, uid, amount) {
  await updateDoc(playerRef(code, uid), { cashOut: amount });
}

async function endGame(code) {
  await updateDoc(gameRef(code), { status: "ended", endedAt: Timestamp.now() });
}

// Applies a buy-in/cash-out correction to a player's raw Firestore data in
// memory — shared by editPlayerEntry below.
function computeUpdatedPlayerData(data, field, buyInId, newAmount) {
  const updated = { ...data };
  if (field === "cashOut") {
    updated.cashOut = newAmount;
  } else {
    const buyIns = [...(data.buyIns || [])];
    const idx = buyIns.findIndex((b) => b.id === buyInId);
    if (idx !== -1) {
      buyIns[idx] = { ...buyIns[idx], amount: newAmount };
    }
    updated.buyIns = buyIns;
  }
  return updated;
}

// Only the host can open the Edit sheet at all (row actions are host-gated),
// so a correction here always applies immediately — no approval needed
// since there's no one else who could have written the value in the first
// place.
async function editPlayerEntry(code, playerUid, field, buyInId, newAmount) {
  const pRef = playerRef(code, playerUid);
  await runTransaction(db, async (tx) => {
    const snap = await tx.get(pRef);
    if (!snap.exists()) return;
    tx.set(pRef, computeUpdatedPlayerData(snap.data(), field, buyInId, newAmount));
  });
}

// ---------------------------------------------------------------------
// Derived player helpers — mirrors GamePlayer computed properties
// ---------------------------------------------------------------------

function totalBuyIn(player) {
  return (player.buyIns || []).reduce((sum, b) => sum + b.amount, 0);
}
function hasCashedOut(player) {
  return player.cashOut !== undefined && player.cashOut !== null;
}
function netOf(player) {
  return hasCashedOut(player) ? player.cashOut - totalBuyIn(player) : null;
}

// ---------------------------------------------------------------------
// Settlement — mirrors PokerTracker/Services/SettlementCalculator.swift
// ---------------------------------------------------------------------

function calculateSettlement(players) {
  const balances = players
    .filter((p) => hasCashedOut(p))
    .map((p) => ({ name: p.name, amount: netOf(p) }));

  const creditors = balances.filter((b) => b.amount > 0.005).sort((a, b) => b.amount - a.amount);
  const debtors = balances.filter((b) => b.amount < -0.005).sort((a, b) => a.amount - b.amount);

  const transactions = [];
  let i = 0;
  let j = 0;
  while (i < debtors.length && j < creditors.length) {
    const owed = -debtors[i].amount;
    const due = creditors[j].amount;
    const amount = Math.min(owed, due);
    if (amount > 0.005) {
      transactions.push({ from: debtors[i].name, to: creditors[j].name, amount });
    }
    debtors[i].amount += amount;
    creditors[j].amount -= amount;
    if (Math.abs(debtors[i].amount) < 0.005) i++;
    if (Math.abs(creditors[j].amount) < 0.005) j++;
  }
  return transactions;
}

// ---------------------------------------------------------------------
// Local history — mirrors PokerTracker/Services/LocalHistoryStore.swift
// ---------------------------------------------------------------------

const HISTORY_KEY = "poker.history.entries";
const ACTIVE_CODE_KEY = "poker.history.activeCode";
const NAME_KEY = "poker.playerName";
const LAST_BUYIN_KEY = "poker.lastDefaultBuyIn";
const LAST_CHIPVALUE_KEY = "poker.lastChipValue";

function loadHistory() {
  try {
    return JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
  } catch {
    return [];
  }
}
function saveHistoryEntry(entry) {
  const entries = loadHistory().filter((e) => e.code !== entry.code);
  entries.unshift(entry);
  localStorage.setItem(HISTORY_KEY, JSON.stringify(entries));
}
function getActiveCode() {
  return localStorage.getItem(ACTIVE_CODE_KEY);
}
function setActiveCode(code) {
  localStorage.setItem(ACTIVE_CODE_KEY, code);
}
function clearActiveCode() {
  localStorage.removeItem(ACTIVE_CODE_KEY);
}

// ---------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------

const currencyFormatter = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
});
function money(amount) {
  return currencyFormatter.format(amount);
}
function moneySigned(amount) {
  return amount > 0 ? "+" + money(amount) : money(amount);
}
function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text ?? "";
  return div.innerHTML;
}
function round2(n) {
  return Math.round(n * 100) / 100;
}

// ---------------------------------------------------------------------
// Chip-aware amount input — lets someone enter either a chip count or a
// dollar amount and converts between them live, when the game has a
// chip ratio set. Falls back to a plain dollar field when it doesn't.
// ---------------------------------------------------------------------

function mountAmountInput(container, { chipsPerDollar, initialDollars = "", idPrefix = "amt" }) {
  const dollarId = `${idPrefix}-dollars`;

  if (!chipsPerDollar) {
    container.innerHTML = `<input class="field" id="${dollarId}" type="number" inputmode="decimal" value="${initialDollars}" min="0" />`;
    return { getAmount: () => parseFloat(document.getElementById(dollarId).value) };
  }

  const chipId = `${idPrefix}-chips`;
  const readoutId = `${idPrefix}-readout`;
  let mode = "chips";
  const initialChips =
    initialDollars !== "" && isFinite(initialDollars) ? round2(initialDollars * chipsPerDollar) : "";

  container.innerHTML = `
    <div class="amount-toggle">
      <button type="button" class="amount-toggle-btn active" data-mode="chips">Chips</button>
      <button type="button" class="amount-toggle-btn" data-mode="dollars">$</button>
    </div>
    <input class="field" id="${chipId}" type="number" inputmode="decimal" value="${initialChips}" min="0" placeholder="e.g. 500" />
    <input class="field" id="${dollarId}" type="number" inputmode="decimal" value="${initialDollars}" min="0" hidden />
    <p class="amount-readout" id="${readoutId}"></p>
  `;

  const chipInput = container.querySelector(`#${chipId}`);
  const dollarInput = container.querySelector(`#${dollarId}`);
  const readout = container.querySelector(`#${readoutId}`);
  const buttons = container.querySelectorAll(".amount-toggle-btn");

  function updateReadout() {
    if (mode === "chips") {
      const chips = parseFloat(chipInput.value);
      readout.textContent = isFinite(chips) ? `= ${money(chips / chipsPerDollar)}` : "";
    } else {
      const dollars = parseFloat(dollarInput.value);
      readout.textContent = isFinite(dollars) ? `= ${Math.round(dollars * chipsPerDollar)} chips` : "";
    }
  }

  buttons.forEach((btn) => {
    btn.onclick = () => {
      const newMode = btn.dataset.mode;
      if (newMode === mode) return;
      // Carry the value over converted into the new unit — otherwise the
      // field you're switching to keeps whatever stale number it had
      // before, and submitting from there would silently save that
      // instead of what you just typed.
      if (newMode === "dollars") {
        const chips = parseFloat(chipInput.value);
        dollarInput.value = isFinite(chips) ? round2(chips / chipsPerDollar) : "";
      } else {
        const dollars = parseFloat(dollarInput.value);
        chipInput.value = isFinite(dollars) ? round2(dollars * chipsPerDollar) : "";
      }
      mode = newMode;
      buttons.forEach((b) => b.classList.toggle("active", b === btn));
      chipInput.hidden = mode !== "chips";
      dollarInput.hidden = mode !== "dollars";
      updateReadout();
    };
  });
  chipInput.oninput = updateReadout;
  dollarInput.oninput = updateReadout;
  updateReadout();

  return {
    getAmount: () => {
      if (mode === "chips") {
        const chips = parseFloat(chipInput.value);
        return isFinite(chips) ? round2(chips / chipsPerDollar) : NaN;
      }
      return parseFloat(dollarInput.value);
    },
  };
}

// ---------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------

const state = {
  uid: null,
  playerName: localStorage.getItem(NAME_KEY) || "",
  tab: "play", // 'play' | 'history'
  code: null,
  game: null,
  players: [],
  resumeCode: null,
  error: null,
  busy: false,
  unsubGame: null,
  unsubPlayers: null,
  historyEntries: [],
  historyDetail: null,
  showSettlement: false,
};

const contentEl = document.getElementById("content");
const topbarEl = document.getElementById("topbar");
const tabbarEl = document.getElementById("tabbar");

function setError(message) {
  state.error = message;
  render();
}

// ---------------------------------------------------------------------
// Screen transitions
// ---------------------------------------------------------------------

function detachGameListeners() {
  state.unsubGame?.();
  state.unsubPlayers?.();
  state.unsubGame = null;
  state.unsubPlayers = null;
}

function enterGame(code) {
  detachGameListeners();
  state.code = code;
  state.resumeCode = null;
  setActiveCode(code);

  state.unsubGame = listenToGame(code, (game) => {
    const wasEnded = state.game?.status === "ended";
    state.game = game;
    if (game && game.status === "ended" && !wasEnded) {
      clearActiveCode();
      saveHistorySnapshot(game);
      state.showSettlement = true;
      // If anyone had a buy-in/cash-out/edit sheet open when the game ended,
      // close it — otherwise it stacks behind the settlement overlay (two
      // ".sheet" elements at once) and could still silently write to a
      // game that's already locked in.
      closeSheet();
    }
    render();
  });
  state.unsubPlayers = listenToPlayers(code, (players) => {
    state.players = players;
    render();
  });

  render();
}

function leaveGame() {
  const leavingCode = state.code;
  const wasActive = state.game?.status === "active";
  detachGameListeners();
  state.code = null;
  state.game = null;
  state.players = [];
  state.showSettlement = false;
  if (wasActive && leavingCode) {
    state.resumeCode = leavingCode;
  }
  render();
}

function saveHistorySnapshot(game) {
  const results = state.players.map((p) => ({
    uid: p.uid,
    name: p.name,
    totalBuyIn: totalBuyIn(p),
    cashOut: p.cashOut ?? null,
    net: netOf(p),
  }));
  const mine = results.find((r) => r.uid === state.uid);
  saveHistoryEntry({
    code: game.code,
    name: game.name,
    date: new Date().toISOString(),
    yourNet: mine ? mine.net : null,
    players: results,
  });
}

async function checkResume() {
  const code = getActiveCode();
  if (!code) return;
  try {
    const { game } = await fetchGameWithPlayers(code);
    if (game.status === "active") {
      state.resumeCode = code;
      render();
    } else {
      clearActiveCode();
    }
  } catch {
    clearActiveCode();
  }
}

// ---------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------

function render() {
  renderTopbar();
  renderTabbar();
  if (state.tab === "history") {
    renderHistory();
  } else if (state.code && state.game) {
    renderRoom();
  } else if (state.code && !state.game) {
    contentEl.innerHTML = `<div class="loading"><div class="spinner"></div><p>Loading game…</p></div>`;
  } else {
    renderHome();
  }
}

function renderTopbar() {
  if (state.tab === "play" && state.code && state.game) {
    topbarEl.hidden = false;
    topbarEl.innerHTML = `
      <button class="icon-btn" id="btn-leave" aria-label="Back">‹</button>
      <div class="topbar-title">
        <span class="code-text">${escapeHtml(state.game.code)}</span>
        <span class="topbar-name">${escapeHtml(state.game.name)}</span>
      </div>
      <div class="topbar-actions">
        <button class="icon-btn" id="btn-copy" aria-label="Copy code">⧉</button>
        <button class="icon-btn" id="btn-share" aria-label="Share code">↑</button>
      </div>`;
    document.getElementById("btn-leave").onclick = leaveGame;
    document.getElementById("btn-copy").onclick = async () => {
      try {
        await navigator.clipboard.writeText(state.game.code);
      } catch {
        /* clipboard unavailable, ignore */
      }
    };
    document.getElementById("btn-share").onclick = async () => {
      const text = `Join my poker game! Code: ${state.game.code}`;
      if (navigator.share) {
        try {
          await navigator.share({ text });
        } catch {
          /* user cancelled, ignore */
        }
      } else {
        try {
          await navigator.clipboard.writeText(text);
          setError("Copied — paste it wherever you want to share it.");
        } catch {
          /* ignore */
        }
      }
    };
  } else {
    topbarEl.hidden = true;
    topbarEl.innerHTML = "";
  }
}

function renderTabbar() {
  tabbarEl.innerHTML = `
    <button class="tab-btn ${state.tab === "play" ? "active" : ""}" id="tab-play">
      <span class="tab-icon">♠</span><span>Play</span>
    </button>
    <button class="tab-btn ${state.tab === "history" ? "active" : ""}" id="tab-history">
      <span class="tab-icon">↻</span><span>History</span>
    </button>`;
  document.getElementById("tab-play").onclick = () => {
    state.tab = "play";
    render();
  };
  document.getElementById("tab-history").onclick = () => {
    state.tab = "history";
    state.historyEntries = loadHistory();
    state.historyDetail = null;
    render();
  };
}

function renderHome() {
  contentEl.innerHTML = `
    <div class="home">
      <div class="home-hero">
        <h1>🃏 Poker Tracker</h1>
        <p>Track buy-ins, cash-outs, and settle up.</p>
      </div>

      <label class="field-label" for="name-input">Your name</label>
      <input class="field" id="name-input" type="text" placeholder="e.g. Alex" maxlength="30" value="${escapeHtml(
        state.playerName
      )}" autocomplete="name" />

      ${
        state.resumeCode
          ? `<button class="btn outline" id="btn-resume">↩ Rejoin game ${escapeHtml(state.resumeCode)}</button>`
          : ""
      }

      ${state.error ? `<p class="error-text">${escapeHtml(state.error)}</p>` : ""}

      <div class="home-actions">
        <button class="btn primary" id="btn-host">Host New Game</button>
        <button class="btn secondary" id="btn-join">Join Game</button>
      </div>
    </div>`;

  const nameInput = document.getElementById("name-input");
  nameInput.oninput = () => {
    state.playerName = nameInput.value;
    localStorage.setItem(NAME_KEY, state.playerName);
    document.getElementById("btn-host").disabled = !state.playerName.trim();
    document.getElementById("btn-join").disabled = !state.playerName.trim();
  };

  const nameGiven = () => {
    if (!state.playerName.trim()) {
      setError("Enter your name first.");
      return false;
    }
    return true;
  };

  document.getElementById("btn-host").disabled = !state.playerName.trim();
  document.getElementById("btn-join").disabled = !state.playerName.trim();

  document.getElementById("btn-resume")?.addEventListener("click", () => {
    enterGame(state.resumeCode);
  });

  document.getElementById("btn-host").onclick = () => {
    if (nameGiven()) openHostSheet();
  };
  document.getElementById("btn-join").onclick = () => {
    if (nameGiven()) openJoinSheet();
  };
}

function openHostSheet() {
  const lastBuyIn = localStorage.getItem(LAST_BUYIN_KEY) || "20";
  const lastChipValue = localStorage.getItem(LAST_CHIPVALUE_KEY) || "";

  openSheet(`
    <h2>Host New Game</h2>
    <label class="field-label" for="sheet-game-name">Game name (optional)</label>
    <input class="field" id="sheet-game-name" type="text" placeholder="Friday Night Poker" maxlength="40" />
    <label class="field-label" for="sheet-buyin">Default buy-in ($)</label>
    <input class="field" id="sheet-buyin" type="number" inputmode="decimal" value="${escapeHtml(lastBuyIn)}" min="0.01" step="0.01" />
    <label class="field-label" for="sheet-chipvalue">Chip value for that buy-in (optional)</label>
    <input class="field" id="sheet-chipvalue" type="number" inputmode="decimal" placeholder="e.g. 500" value="${escapeHtml(
      lastChipValue
    )}" min="0.01" step="0.01" />
    <p class="sheet-note">If a buy-in hands out chips labeled in a different number (like a stack marked "500" for a $20 buy-in), enter that number here — everyone can then enter chip counts at cash-out instead of doing the math. Leave blank to just use dollars. Remembered for next time either way.</p>
    <p class="sheet-error" id="sheet-error"></p>
    <div class="sheet-actions">
      <button class="btn outline" data-close>Cancel</button>
      <button class="btn primary" id="sheet-submit">Create</button>
    </div>
  `);
  document.getElementById("sheet-submit").onclick = async (e) => {
    const button = e.currentTarget;
    const errorEl = document.getElementById("sheet-error");
    errorEl.textContent = "";

    const name = document.getElementById("sheet-game-name").value.trim().slice(0, 40);
    const buyInRaw = document.getElementById("sheet-buyin").value.trim();
    const chipValueRaw = document.getElementById("sheet-chipvalue").value.trim();

    const defaultBuyIn = parseFloat(buyInRaw);
    if (buyInRaw === "" || !isFinite(defaultBuyIn) || defaultBuyIn <= 0) {
      errorEl.textContent = "Enter a valid buy-in amount greater than 0.";
      return;
    }

    let chipsPerDollar = null;
    let chipValue = null;
    if (chipValueRaw !== "") {
      chipValue = parseFloat(chipValueRaw);
      if (!isFinite(chipValue) || chipValue <= 0) {
        errorEl.textContent = "Chip value must be a positive number.";
        return;
      }
      if (chipValue === defaultBuyIn) {
        errorEl.textContent =
          "Chip value is the same as the dollar buy-in, so there's nothing to convert — leave it blank instead, or enter the actual chip number if it's different.";
        return;
      }
      chipsPerDollar = chipValue / defaultBuyIn;
    }

    button.disabled = true;
    try {
      const game = await createGame(name, state.uid, state.playerName, defaultBuyIn, chipsPerDollar);
      localStorage.setItem(LAST_BUYIN_KEY, String(defaultBuyIn));
      if (chipValue) {
        localStorage.setItem(LAST_CHIPVALUE_KEY, String(chipValue));
      } else {
        localStorage.removeItem(LAST_CHIPVALUE_KEY);
      }
      closeSheet();
      enterGame(game.code);
    } catch (err) {
      errorEl.textContent = err.message;
      button.disabled = false;
    }
  };
}

function openJoinSheet() {
  openSheet(`
    <h2>Join Game</h2>
    <label class="field-label" for="sheet-code">Game code</label>
    <input class="field" id="sheet-code" type="text" placeholder="e.g. PK4X9" maxlength="8" autocapitalize="characters" autocorrect="off" />
    <p class="sheet-error" id="sheet-error"></p>
    <div class="sheet-actions">
      <button class="btn outline" data-close>Cancel</button>
      <button class="btn primary" id="sheet-submit">Join</button>
    </div>
  `);
  document.getElementById("sheet-submit").onclick = async (e) => {
    const button = e.currentTarget;
    const errorEl = document.getElementById("sheet-error");
    const code = document.getElementById("sheet-code").value.trim();
    if (!code) {
      errorEl.textContent = "Enter a game code.";
      return;
    }
    button.disabled = true;
    try {
      const game = await joinGame(code, state.uid, state.playerName);
      closeSheet();
      enterGame(game.code);
    } catch (err) {
      errorEl.textContent = err.message;
      button.disabled = false;
    }
  };
}

function renderRoom() {
  const game = state.game;
  const players = state.players;
  const myUid = state.uid;
  const isHost = game.hostId === myUid;
  const active = game.status === "active";
  const hostName = players.find((p) => p.uid === game.hostId)?.name;

  const chipsPerDollar = game.chipsPerDollar || null;

  const rowsHtml = players
    .map((p) => {
      const net = netOf(p);
      const netHtml =
        net === null
          ? `<span class="net pending">In play</span>`
          : `<span class="net ${net >= 0 ? "pos" : "neg"}">${moneySigned(net)}</span>`;
      const chipsNote = chipsPerDollar ? ` · ${Math.round(totalBuyIn(p) * chipsPerDollar)} chips` : "";
      const deletable = active && isHost && p.buyIns.length === 0 && !hasCashedOut(p);
      return `
        <div class="row" data-uid="${p.uid}">
          <div class="row-main">
            <div>
              <div class="name-line">
                <span class="player-name">${escapeHtml(p.name)}</span>
                ${p.uid === myUid ? '<span class="you-pill">you</span>' : ""}
              </div>
              <div class="buyin-line">Buy-in: ${money(totalBuyIn(p))}${chipsNote}</div>
            </div>
            ${netHtml}
          </div>
          ${
            active && isHost
              ? `<div class="row-actions">
                   <button class="row-action-btn" data-action="buyin" data-uid="${p.uid}">+ Buy-in</button>
                   ${!hasCashedOut(p) ? `<button class="row-action-btn" data-action="cashout" data-uid="${p.uid}">✓ Cash out</button>` : ""}
                   ${
                     p.buyIns.length || hasCashedOut(p)
                       ? `<button class="row-action-btn ghost" data-action="edit" data-uid="${p.uid}">✎ Edit</button>`
                       : ""
                   }
                   ${deletable ? `<button class="row-action-btn danger" data-action="delete" data-uid="${p.uid}">🗑 Delete</button>` : ""}
                 </div>`
              : ""
          }
        </div>`;
    })
    .join("");

  const stillIn = players.filter((p) => !hasCashedOut(p));

  contentEl.innerHTML = `
    <div class="room">
      <div class="game-status">
        <span class="status-dot ${active ? "live" : ""}"></span>
        ${active ? "Game in progress" : "Game ended"}${hostName ? ` · Hosted by ${escapeHtml(hostName)}` : ""}
      </div>

      <div class="section-label">Players (${players.length})</div>
      ${isHost && active ? `<button class="btn outline" id="btn-add-player">+ Add Player</button>` : ""}
      <div class="card-list">${rowsHtml}</div>

      ${state.error ? `<p class="error-text">${escapeHtml(state.error)}</p>` : ""}

      ${
        isHost && active
          ? `<button class="btn danger" id="btn-end">End Game &amp; Settle Up</button>
             <p class="hint">Enabled once everyone has cashed out</p>`
          : ""
      }
      ${!active ? `<button class="btn primary" id="btn-view-settlement">View Settlement</button>` : ""}
    </div>`;

  contentEl.querySelectorAll('[data-action="buyin"]').forEach((btn) => {
    btn.onclick = () => openBuyInSheet(players.find((p) => p.uid === btn.dataset.uid));
  });
  contentEl.querySelectorAll('[data-action="cashout"]').forEach((btn) => {
    btn.onclick = () => openCashOutSheet(players.find((p) => p.uid === btn.dataset.uid));
  });
  contentEl.querySelectorAll('[data-action="edit"]').forEach((btn) => {
    btn.onclick = () => openEditSheet(players.find((p) => p.uid === btn.dataset.uid));
  });
  contentEl.querySelectorAll('[data-action="delete"]').forEach((btn) => {
    btn.onclick = () => {
      const player = players.find((p) => p.uid === btn.dataset.uid);
      if (!player) return;
      if (confirm(`Remove ${player.name} from the game?`)) {
        deletePlayer(state.code, player.uid).catch((err) => setError(err.message));
      }
    };
  });

  document.getElementById("btn-add-player")?.addEventListener("click", openAddPlayerSheet);

  document.getElementById("btn-end")?.addEventListener("click", () => {
    if (stillIn.length > 0) {
      setError(`Still in play: ${stillIn.map((p) => p.name).join(", ")}`);
      return;
    }
    if (confirm("End the game for everyone? This locks in all buy-ins and cash-outs.")) {
      endGame(state.code).catch((err) => setError(err.message));
    }
  });

  document.getElementById("btn-view-settlement")?.addEventListener("click", () => {
    state.showSettlement = true;
    render();
  });

  if (state.showSettlement && !document.getElementById("settlement-overlay")) {
    renderSettlementOverlay();
  }
}

function openAddPlayerSheet() {
  openSheet(`
    <h2>Add Player</h2>
    <label class="field-label" for="sheet-player-name">Name</label>
    <input class="field" id="sheet-player-name" type="text" placeholder="e.g. Sam" maxlength="30" />
    <p class="sheet-note">They won't need the app — you'll record their buy-ins and cash-out for them, same as anyone else at the table.</p>
    <p class="sheet-error" id="sheet-error"></p>
    <div class="sheet-actions">
      <button class="btn outline" data-close>Cancel</button>
      <button class="btn primary" id="sheet-submit">Add</button>
    </div>
  `);
  document.getElementById("sheet-submit").onclick = async (e) => {
    const errorEl = document.getElementById("sheet-error");
    const name = document.getElementById("sheet-player-name").value.trim();
    if (!name) {
      errorEl.textContent = "Enter a name.";
      return;
    }
    e.currentTarget.disabled = true;
    try {
      await addManualPlayer(state.code, name, state.uid);
      closeSheet();
    } catch (err) {
      errorEl.textContent = err.message;
      e.currentTarget.disabled = false;
    }
  };
}

function openBuyInSheet(player) {
  const defaultAmount = state.game.defaultBuyIn;
  const chipsPerDollar = state.game.chipsPerDollar || null;
  openSheet(`
    <h2>Add buy-in for ${escapeHtml(player.name)}</h2>
    <label class="field-label">${chipsPerDollar ? "Chips or $" : "Amount"}</label>
    <div id="amount-input"></div>
    <p class="sheet-error" id="sheet-error"></p>
    <div class="sheet-actions">
      <button class="btn outline" data-close>Cancel</button>
      <button class="btn primary" id="sheet-submit">Add</button>
    </div>
  `);
  const amountCtl = mountAmountInput(document.getElementById("amount-input"), {
    chipsPerDollar,
    initialDollars: defaultAmount,
    idPrefix: "buyin",
  });
  document.getElementById("sheet-submit").onclick = async (e) => {
    const amount = amountCtl.getAmount();
    if (!isFinite(amount) || amount <= 0) {
      document.getElementById("sheet-error").textContent = "Enter an amount greater than 0.";
      return;
    }
    e.currentTarget.disabled = true;
    try {
      await addBuyIn(state.code, player.uid, amount);
      closeSheet();
    } catch (err) {
      document.getElementById("sheet-error").textContent = err.message;
      e.currentTarget.disabled = false;
    }
  };
}

function openCashOutSheet(player) {
  const chipsPerDollar = state.game.chipsPerDollar || null;
  openSheet(`
    <h2>Cash out ${escapeHtml(player.name)}</h2>
    <label class="field-label">${chipsPerDollar ? "Final chip count" : "Final amount"}</label>
    <div id="amount-input"></div>
    <p class="sheet-note">Enter the total ${
      chipsPerDollar ? "chips" : "value"
    } they're cashing out with, not the profit or loss.</p>
    <p class="sheet-error" id="sheet-error"></p>
    <div class="sheet-actions">
      <button class="btn outline" data-close>Cancel</button>
      <button class="btn primary" id="sheet-submit">Confirm</button>
    </div>
  `);
  const amountCtl = mountAmountInput(document.getElementById("amount-input"), {
    chipsPerDollar,
    initialDollars: "",
    idPrefix: "cashout",
  });
  document.getElementById("sheet-submit").onclick = async (e) => {
    const amount = amountCtl.getAmount();
    if (!isFinite(amount) || amount < 0) {
      document.getElementById("sheet-error").textContent = "Enter a valid amount.";
      return;
    }
    e.currentTarget.disabled = true;
    try {
      await setCashOut(state.code, player.uid, amount);
      closeSheet();
    } catch (err) {
      document.getElementById("sheet-error").textContent = err.message;
      e.currentTarget.disabled = false;
    }
  };
}

function openEditSheet(player) {
  const items = [
    ...player.buyIns.map((b) => ({ label: "Buy-in", amount: b.amount, field: "buyIn", buyInId: b.id })),
    ...(hasCashedOut(player) ? [{ label: "Cash-out", amount: player.cashOut, field: "cashOut", buyInId: null }] : []),
  ];

  openSheet(`
    <h2>Edit ${escapeHtml(player.name)}'s entries</h2>
    <div class="edit-item-list">
      ${items
        .map(
          (item, idx) => `
        <button class="edit-item" data-idx="${idx}">
          <span>${item.label}</span>
          <span class="edit-item-amount">${money(item.amount)}</span>
        </button>`
        )
        .join("")}
    </div>
    <div id="edit-amount-step" hidden>
      <label class="field-label">New amount</label>
      <div id="amount-input"></div>
      <p class="sheet-error" id="sheet-error"></p>
      <div class="sheet-actions">
        <button class="btn outline" data-close>Cancel</button>
        <button class="btn primary" id="sheet-submit">Save</button>
      </div>
    </div>
  `);

  contentSheetItems(items, player);
}

function contentSheetItems(items, player) {
  const chipsPerDollar = state.game.chipsPerDollar || null;
  document.querySelectorAll(".edit-item").forEach((btn) => {
    btn.onclick = () => {
      const item = items[Number(btn.dataset.idx)];
      document.querySelector(".edit-item-list").hidden = true;
      document.querySelector(".sheet h2").textContent = `New ${item.label.toLowerCase()} amount`;
      const step = document.getElementById("edit-amount-step");
      step.hidden = false;
      const amountCtl = mountAmountInput(document.getElementById("amount-input"), {
        chipsPerDollar,
        initialDollars: item.amount,
        idPrefix: "edit",
      });

      document.getElementById("sheet-submit").onclick = async (e) => {
        const newAmount = amountCtl.getAmount();
        if (!isFinite(newAmount) || newAmount < 0) {
          document.getElementById("sheet-error").textContent = "Enter a valid amount.";
          return;
        }
        e.currentTarget.disabled = true;
        try {
          await editPlayerEntry(state.code, player.uid, item.field, item.buyInId, newAmount);
          closeSheet();
        } catch (err) {
          document.getElementById("sheet-error").textContent = err.message;
          e.currentTarget.disabled = false;
        }
      };
    };
  });
}

function renderSettlementOverlay() {
  const players = state.players;
  const transactions = calculateSettlement(players);
  const totalPot = players.reduce((sum, p) => sum + totalBuyIn(p), 0);
  const sorted = [...players].sort((a, b) => (netOf(b) ?? 0) - (netOf(a) ?? 0));

  const overlay = document.createElement("div");
  overlay.className = "overlay";
  overlay.id = "settlement-overlay";
  overlay.innerHTML = `
    <div class="sheet settlement-sheet">
      <h2>${escapeHtml(state.game.name)}</h2>
      <div class="section-label">Results</div>
      <div class="card-list">
        ${sorted
          .map((p) => {
            const net = netOf(p) ?? 0;
            return `<div class="row simple"><span class="player-name">${escapeHtml(p.name)}</span><span class="net ${
              net >= 0 ? "pos" : "neg"
            }">${moneySigned(net)}</span></div>`;
          })
          .join("")}
      </div>

      <div class="section-label">Who pays who</div>
      <div class="card-list">
        ${
          transactions.length
            ? transactions
                .map(
                  (tx) =>
                    `<div class="tx-row"><span class="tx-name">${escapeHtml(tx.from)}</span><span class="tx-arrow">→</span><span class="tx-name">${escapeHtml(
                      tx.to
                    )}</span><span class="tx-amount">${money(tx.amount)}</span></div>`
                )
                .join("")
            : `<p class="sheet-note" style="padding:0.85rem;">Everyone's settled up. 🎉</p>`
        }
      </div>

      <div class="card-list">
        <div class="pot-row"><span>Total pot</span><span>${money(totalPot)}</span></div>
      </div>

      <div class="sheet-actions">
        <button class="btn primary" id="settlement-done">Done</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);
  document.getElementById("settlement-done").onclick = () => {
    overlay.remove();
    state.showSettlement = false;
    leaveGame();
  };
}

function renderHistory() {
  if (state.historyDetail) {
    const entry = state.historyDetail;
    const sorted = [...entry.players].sort((a, b) => (b.net ?? 0) - (a.net ?? 0));
    contentEl.innerHTML = `
      <div class="room">
        <button class="btn outline" id="btn-back-history">‹ Back</button>
        <div class="section-label">${escapeHtml(entry.name)}</div>
        <div class="card-list">
          ${sorted
            .map(
              (p) =>
                `<div class="row simple"><span class="player-name">${escapeHtml(p.name)}</span><span class="net ${
                  (p.net ?? 0) >= 0 ? "pos" : "neg"
                }">${moneySigned(p.net ?? 0)}</span></div>`
            )
            .join("")}
        </div>
        <div class="card-list">
          <div class="pot-row"><span>Game code</span><span>${escapeHtml(entry.code)}</span></div>
        </div>
      </div>`;
    document.getElementById("btn-back-history").onclick = () => {
      state.historyDetail = null;
      render();
    };
    return;
  }

  const entries = state.historyEntries;
  if (!entries.length) {
    contentEl.innerHTML = `<div class="empty-state"><p class="empty-title">No games yet</p><p class="empty-sub">Games you finish will show up here.</p></div>`;
    return;
  }

  contentEl.innerHTML = `
    <div class="section-label">History</div>
    <div class="card-list">
      ${entries
        .map(
          (entry, idx) => `
        <button class="row hist-row" data-idx="${idx}">
          <div>
            <div class="player-name">${escapeHtml(entry.name)}</div>
            <div class="buyin-line">${new Date(entry.date).toLocaleString(undefined, {
              dateStyle: "medium",
              timeStyle: "short",
            })}</div>
          </div>
          ${
            entry.yourNet !== null && entry.yourNet !== undefined
              ? `<span class="net ${entry.yourNet >= 0 ? "pos" : "neg"}">${moneySigned(entry.yourNet)}</span>`
              : ""
          }
        </button>`
        )
        .join("")}
    </div>`;

  contentEl.querySelectorAll(".hist-row").forEach((row) => {
    row.onclick = () => {
      state.historyDetail = entries[Number(row.dataset.idx)];
      render();
    };
  });
}

// ---------------------------------------------------------------------
// Sheet (modal) helper
// ---------------------------------------------------------------------

function openSheet(innerHtml) {
  closeSheet();
  const overlay = document.createElement("div");
  overlay.className = "overlay";
  overlay.id = "active-overlay";
  overlay.innerHTML = `<div class="sheet">${innerHtml}</div>`;
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) closeSheet();
  });
  overlay.querySelectorAll("[data-close]").forEach((btn) => (btn.onclick = closeSheet));
  document.body.appendChild(overlay);
}
function closeSheet() {
  document.getElementById("active-overlay")?.remove();
}

// ---------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------

async function boot() {
  contentEl.innerHTML = `<div class="loading"><div class="spinner"></div><p>Connecting…</p></div>`;
  try {
    state.uid = await ensureSignedIn();
  } catch (err) {
    contentEl.innerHTML = `<div class="loading"><p class="error-text">Couldn't connect: ${escapeHtml(
      err.message
    )}</p></div>`;
    return;
  }
  await checkResume();
  render();
}

boot();
