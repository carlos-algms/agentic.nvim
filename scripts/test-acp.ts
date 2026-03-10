/**
 * Test ACP model switching over stdio JSON-RPC for any provider.
 *
 * Usage:
 *   bun run scripts/test-acp.ts "gemini --experimental-acp"
 *   bun run scripts/test-acp.ts "claude-agent-acp"
 *   bun run scripts/test-acp.ts "codex-acp"
 *   bun run scripts/test-acp.ts "opencode"
 *   bun run scripts/test-acp.ts "auggie"
 *   bun run scripts/test-acp.ts "vibe-acp"
 *
 * Spawns the provider, sends initialize + session/new,
 * prints available models (configOptions + legacy), then tries
 * session/set_config_option and session/set_model to switch.
 */

import { spawn } from 'bun';

const commandStr: string | undefined = process.argv[2];

if (!commandStr) {
  console.error('Usage: bun run scripts/test-acp.ts "<provider-command>"');
  console.error(
    'Example: bun run scripts/test-acp.ts "gemini --experimental-acp"',
  );
  process.exit(1);
}

const [command, ...args] = commandStr.split(/\s+/);

let reqId = 0;

function jsonrpc(
  method: string,
  params: Record<string, unknown> = {},
): { id: number; payload: string } {
  const id = ++reqId;
  const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';
  return { id, payload };
}

function log(label: string, data: unknown): void {
  console.log(`\n=== ${label} ===`);
  console.log(JSON.stringify(data, null, 2));
}

type ConfigOption = {
  id: string;
  name: string;
  category?: string;
  type: string;
  currentValue?: string;
  options?: { value: string; name: string; description?: string }[];
};

type LegacyModels = {
  availableModels: {
    modelId: string;
    name: string;
    description?: string;
  }[];
  currentModelId: string;
};

console.log(`Spawning: ${command} ${args.join(' ')}`);

const proc = spawn([command, ...args], {
  stdin: 'pipe',
  stdout: 'pipe',
  stderr: 'inherit',
});

const stdin = proc.stdin!;
const stdout = proc.stdout!;

const messages: Record<string, unknown>[] = [];
let buffer = '';
const decoder = new TextDecoder();
const reader = stdout.getReader();

// Background reader
(async () => {
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    let idx: number;
    while ((idx = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (!line) continue;
      try {
        messages.push(JSON.parse(line));
      } catch {
        console.error('[parse error]', line.slice(0, 120));
      }
    }
  }
})();

async function send(
  method: string,
  params: Record<string, unknown> = {},
): Promise<number> {
  const { id, payload } = jsonrpc(method, params);
  console.log(`\n[send] ${method} (id=${id})`);
  await stdin.write(payload);
  await stdin.flush();
  return id;
}

function drainNotifications(): void {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!('id' in m)) {
      console.log(
        '[notification]',
        (m as { method?: string }).method ?? 'unknown',
      );
      messages.splice(i, 1);
    }
  }
}

async function waitFor(
  id: number,
  timeoutMs = 30_000,
  allowError = false,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    drainNotifications();
    const idx = messages.findIndex((m) => m.id === id);
    if (idx !== -1) {
      const [msg] = messages.splice(idx, 1);
      if ('error' in msg && !allowError) {
        throw new Error(
          `JSON-RPC error for id=${id}: ${JSON.stringify(msg.error)}`,
        );
      }
      return msg;
    }
    await Bun.sleep(50);
  }
  console.error('[timeout] pending messages:', messages.length);
  for (const m of messages) {
    console.error('  ', JSON.stringify(m).slice(0, 200));
  }
  throw new Error(`Timeout waiting for response id=${id}`);
}

try {
  // 1) Initialize
  const initId = await send('initialize', {
    protocolVersion: 1,
    clientInfo: { name: 'agentic-nvim-test', version: '0.0.1' },
    clientCapabilities: {},
  });
  const initResp = await waitFor(initId);
  log('initialize response', initResp);

  // 2) Create session
  const newId = await send('session/new', {
    cwd: process.cwd(),
    mcpServers: [],
  });
  const sessionResp = await waitFor(newId, 60_000);
  log('session/new response', sessionResp);

  const result = sessionResp.result as Record<string, unknown> | undefined;
  if (!result) {
    console.error('No result in session/new response');
    proc.kill();
    process.exit(1);
  }

  const sessionId = result.sessionId as string;

  // -- configOptions (standard ACP) --
  const configOptions = (result.configOptions ?? []) as ConfigOption[];

  const modelConfig = configOptions.find((o) => o.category === 'model');
  const modeConfig = configOptions.find((o) => o.category === 'mode');
  const thoughtConfig = configOptions.find(
    (o) => o.category === 'thought_level',
  );

  log('configOptions (model)', modelConfig ?? 'NOT PRESENT');
  log('configOptions (mode)', modeConfig ?? 'NOT PRESENT');
  log('configOptions (thought_level)', thoughtConfig ?? 'NOT PRESENT');

  // -- legacy models field --
  const legacyModels = result.models as LegacyModels | undefined;
  log('models (legacy field)', legacyModels ?? 'NOT PRESENT');

  // -- legacy modes field --
  const legacyModes = result.modes as Record<string, unknown> | undefined;
  log('modes (legacy field)', legacyModes ?? 'NOT PRESENT');

  // 3) Try session/set_config_option with model category
  if (modelConfig?.options?.length) {
    console.log('\nconfigOptions model options:');
    for (const o of modelConfig.options) {
      const cur = o.value === modelConfig.currentValue ? ' (current)' : '';
      console.log(`  - ${o.value}: ${o.name}${cur}`);
    }

    const target = modelConfig.options.find(
      (o) => o.value !== modelConfig.currentValue,
    );
    if (target) {
      const cfgId = await send('session/set_config_option', {
        sessionId,
        configId: modelConfig.id,
        value: target.value,
      });
      const cfgResp = await waitFor(cfgId);
      log('session/set_config_option (model) response', cfgResp);
    }
  } else {
    console.log('\nNo model configOption. Trying set_config_option anyway...');
    const cfgId = await send('session/set_config_option', {
      sessionId,
      configId: 'model',
      value: 'test-model',
    });
    const cfgResp = await waitFor(cfgId, 30_000, true);
    log('session/set_config_option response', cfgResp);
  }

  // 4) Try session/set_model (legacy/unstable)
  if (legacyModels?.availableModels?.length) {
    console.log('\nLegacy available models:');
    for (const m of legacyModels.availableModels) {
      const cur = m.modelId === legacyModels.currentModelId ? ' (current)' : '';
      console.log(`  - ${m.modelId}: ${m.name}${cur}`);
    }

    const target = legacyModels.availableModels.find(
      (m) => m.modelId !== legacyModels.currentModelId,
    );
    if (target) {
      const setId = await send('session/set_model', {
        sessionId,
        modelId: target.modelId,
      });
      const setResp = await waitFor(setId);
      log('session/set_model response', setResp);
    }
  } else {
    console.log('\nNo legacy models. Trying session/set_model anyway...');
    const setId = await send('session/set_model', {
      sessionId,
      modelId: 'test-model',
    });
    const setResp = await waitFor(setId, 30_000, true);
    log('session/set_model response', setResp);
  }

  // Cleanup
  await send('session/close', { sessionId });
  await Bun.sleep(500);
} catch (err) {
  console.error(err);
  process.exit(1);
} finally {
  proc.kill();
  reader.cancel();
  console.log('\nDone.');
}
