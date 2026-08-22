import assert from 'node:assert/strict';
import test from 'node:test';

import { getHeaderContract } from '../../scripts/build-site-assets.mjs';

test('the generated CSP derives one live script hash and forbids event handlers', () => {
  const contract = getHeaderContract();
  assert.equal(contract.script_hashes.length, 1);
  assert.match(contract.script_hashes[0], /^sha256-[A-Za-z0-9+/]+={0,2}$/);
  assert.deepEqual(
    Object.keys(contract),
    ['generated_headers_base64', 'script_hashes', 'root', 'not_found'],
  );
  assert.match(contract.root.content_security_policy, /script-src 'self' 'sha256-[^']+';/);
  assert.match(contract.root.content_security_policy, /script-src-attr 'none';/);
});

test('the generated CSP keeps stylesheet and font origins self-only', () => {
  const policy = getHeaderContract().root.content_security_policy;
  assert.match(policy, /style-src 'self'; font-src 'self';/);
});
