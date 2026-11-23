import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export async function startRememberedFixture({ sourceRoot, directory, origin, emit }) {
  const { createRemoteAuthority } = await import(pathToFileURL(join(sourceRoot, 'src/remote-authority.mjs')));
  const { createRemoteCompanion } = await import(pathToFileURL(join(sourceRoot, 'src/remote-companion.mjs')));
  const identity = () => {
    const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const jwk = publicKey.export({ format: 'jwk' });
    return {
      publicKey: Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64url'),
      sign: raw => sign('sha256', Buffer.from('Notify remote authorization v1\0' + raw), privateKey).toString('base64url')
    };
  };
  const mac = identity(), phone = identity(), macID = randomUUID(), deviceID = randomUUID();
  const account = { issuer: origin, subject: 'fictional-native-integration' };
  const controller = new AbortController(), req = { headers: { origin } };
  const authority = createRemoteAuthority({ origin, accounts: { authorize: async () => ({ ...account, signal: controller.signal }) } });
  const flow = authority.beginMac({ macID, publicKey: mac.publicKey });
  const registration = authority.registerMac({ id: flow.id, signature: mac.sign(flow.challenge) });
  const pending = await authority.requestPair(req, { setupID: registration.setupID,
    deviceID, publicKey: phone.publicKey, name: 'Fictional integration phone' });
  await authority.decidePair(registration.credential, { id: pending.id, allow: true });
  const enable = await authority.beginRemember(req, { macID, deviceID, optIn: true });
  await authority.finishRemember(req, { id: enable.id, signature: phone.sign(enable.challenge) });
  await writeFile(join(directory, 'identity.json'), JSON.stringify({
    version: 1, origin, macID, publicKey: mac.publicKey, owner: account,
    devices: [{ id: deviceID, name: 'Fictional integration phone', publicKey: phone.publicKey }],
    credential: registration.credential, setupID: registration.setupID
  }), { mode: 0o600 });
  const mutations = [];
  const saveEvidence = () => writeFile(join(directory, 'authority.json'), JSON.stringify({
    status: authority.macStatus(registration.credential), mutations
  }), { mode: 0o600 });
  await saveEvidence();
  const companion = await createRemoteCompanion({
    directory, origin, emit,
    cryptoProcess: () => ({
      async call(op, args) {
        if (op === 'identity') return [...Buffer.from(mac.publicKey, 'base64url')];
        if (op === 'sign') return [...Buffer.from(mac.sign(Buffer.from(args.bytes).toString()), 'base64url')];
        throw Error('MLS is not exercised by the consent fixture');
      }, async close() {}
    }),
    fetchRequest: async (url, options) => {
      const path = url.split('/v1/remote/')[1], input = JSON.parse(options.body);
      const credential = options.headers.Authorization?.slice(7);
      try {
        if (path === 'mac/status') return Response.json(authority.macStatus(credential));
        if (path === 'mac/remember/decision') {
          const result = await authority.decideRemember(credential, input);
          mutations.push({ path, input, result });
          await saveEvidence();
          return Response.json(result);
        }
        return Response.json({ error: 'No foreground relay in this consent fixture' }, { status: 401 });
      } catch (error) {
        if (!error.status) throw error;
        return Response.json({ error: error.message }, { status: error.status });
      }
    }
  });
  return { command: input => companion.command(input), async close() { await companion.close(); authority.close(); } };
}
