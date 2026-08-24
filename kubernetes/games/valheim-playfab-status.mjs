#!/usr/bin/env node
// One-shot status check for a crossplay (PlayFab) Valheim server. See docs/design/monitor-spike.md.
// Usage: node valheim-playfab-status.mjs --name <server name> | --code 123456 | --ip 1.2.3.4:2456 | --entity-id <id>
// Exit: 0 online, 1 no active lobby, 2 usage/API error.

const TITLE_ID = '6E223';
const API = `https://${TITLE_ID}.playfabapi.com`;
const DOTNET_EPOCH_TICKS = 621355968000000000n;

async function playfab(path, body, headers = {}) {
  const res = await fetch(`${API}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok || json.code !== 200) throw new Error(`${path}: HTTP ${res.status} ${json.errorMessage ?? ''}`);
  return json.data;
}

// Pure query core — the future GameDig protocol body (ADR 002).
export async function queryValheimPlayFab({ name, code, ip, entityId }) {
  const login = await playfab('/Client/LoginWithCustomID', {
    TitleId: TITLE_ID, CustomId: 'valheim-playfab-status', CreateAccount: true,
  });
  const token = login.EntityToken.EntityToken;

  const filter = name ? `string_key5 eq '${name}'`
    : code ? `string_key4 eq '${code}'`
    : ip ? `string_key10 eq '${ip}'`
    : `string_key1 eq '${entityId}'`;
  const found = await playfab('/Lobby/FindLobbies',
    { Filter: `${filter} and string_key2 eq 'True'` },
    { 'X-EntityToken': token });

  const lobbies = found.Lobbies ?? [];
  if (lobbies.length === 0) return { online: false };

  // Stale-orphan rule: newest lobby by created-ticks wins (ADR 001).
  const lobby = lobbies.reduce((a, b) =>
    BigInt(a.SearchData?.string_key9 ?? 0) >= BigInt(b.SearchData?.string_key9 ?? 0) ? a : b);
  const sd = lobby.SearchData ?? {};
  const ticks = BigInt(sd.string_key9 ?? 0);
  return {
    online: true,
    players: lobby.CurrentPlayers - 1,      // server occupies one lobby slot
    maxPlayers: lobby.MaxPlayers - 1,
    serverName: sd.string_key5,
    version: sd.string_key6,
    joinCode: sd.string_key4,
    ip: sd.string_key10,
    entityId: sd.string_key1 ?? lobby.Owner?.Id,
    lobbyCreated: ticks > 0n ? new Date(Number((ticks - DOTNET_EPOCH_TICKS) / 10000n)).toISOString() : null,
  };
}

async function main() {
  const args = process.argv.slice(2);
  const get = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
  const key = { name: get('--name'), code: get('--code'), ip: get('--ip'), entityId: get('--entity-id') };
  if (!key.name && !key.code && !key.ip && !key.entityId) {
    console.error('usage: valheim-playfab-status.mjs --name <server name> | --code <join-code> | --ip <ip:port> | --entity-id <id>');
    process.exit(2);
  }
  const status = await queryValheimPlayFab(key);
  console.log(JSON.stringify(status, null, 2));
  console.error(status.online
    ? `${status.serverName}: ONLINE, ${status.players}/${status.maxPlayers} players, join code ${status.joinCode}`
    : 'no active lobby found');
  process.exit(status.online ? 0 : 1);
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  main().catch((e) => { console.error(e.message); process.exit(2); });
}
