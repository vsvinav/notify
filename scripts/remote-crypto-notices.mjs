#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const licenseDirectory = path.join(root, 'crypto/licenses');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const readJSON = file => JSON.parse(fs.readFileSync(file, 'utf8'));

function selectedPackages(metadata) {
  if (!metadata.resolve?.root) throw new Error('Metadata must contain resolve.root and resolve.nodes');
  const nodes = new Map(metadata.resolve.nodes.map(node => [node.id, node]));
  const selected = new Set();
  function visit(id) {
    if (selected.has(id)) return;
    const node = nodes.get(id);
    if (!node) throw new Error(`Missing resolve node: ${id}`);
    selected.add(id);
    for (const dep of node.deps) {
      if (dep.dep_kinds.some(kind => kind.kind !== 'dev')) visit(dep.pkg);
    }
  }
  visit(metadata.resolve.root);
  const packages = new Map(metadata.packages.map(pkg => [pkg.id, pkg]));
  return [...selected].filter(id => id !== metadata.resolve.root).map(id => {
    if (!packages.has(id)) throw new Error(`Missing resolved package: ${id}`);
    return packages.get(id);
  });
}

function requireLicenseTexts(expression, texts) {
  // This is an explicit policy for this lockfile, not a general SPDX parser.
  const distributionLicenses = {
    MIT: ['MIT'],
    'MIT OR Apache-2.0': ['MIT'],
    'Apache-2.0 OR MIT': ['MIT'],
    'MIT/Apache-2.0': ['MIT'],
    'Unlicense OR MIT': ['MIT'],
    'BSD-2-Clause OR Apache-2.0 OR MIT': ['MIT'],
    '(MIT OR Apache-2.0) AND Unicode-3.0': ['MIT', 'Unicode-3.0'],
    'Apache-2.0': ['Apache-2.0'],
    'BSD-3-Clause': ['BSD-3-Clause'],
    'MPL-2.0': ['MPL-2.0'],
  };
  const signatures = {
    MIT: /Permission is hereby granted, free of charge.*above copyright notice and this permission notice.*SOFTWARE IS PROVIDED/i,
    'Apache-2.0': /Apache License Version 2\.0, January 2004.*END OF TERMS AND CONDITIONS/i,
    'BSD-3-Clause': /Redistribution and use in source and binary forms.*Neither the name.*THIS SOFTWARE IS PROVIDED/i,
    'Unicode-3.0': /UNICODE LICENSE V3.*COPYRIGHT AND PERMISSION NOTICE.*IN NO EVENT/i,
    'MPL-2.0': /Mozilla Public License Version 2\.0.*3\.2\. Distribution of Executable Form.*Exhibit B/i,
  };
  const required = distributionLicenses[expression];
  if (!required) throw new Error(`Unsupported license expression: ${expression}`);
  for (const license of required) {
    if (!texts.some(text => text.length > 800 && signatures[license].test(text.replace(/\s+/g, ' ')))) {
      throw new Error(`Missing complete required ${license} license text (${expression})`);
    }
  }
  return required.join(' AND ');
}

function packageFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0).flatMap(entry => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) return packageFiles(file);
    if (!entry.isFile()) throw new Error(`Unexpected non-regular package file: ${file}`);
    return [file];
  });
}

function generate(wasmFile, nativeFile, mobileOutput) {
  const provenance = readJSON(path.join(licenseDirectory, 'provenance.json')).inputs;
  const packages = new Map();
  for (const [target, file] of [
    ['wasm32-unknown-unknown', wasmFile], ['aarch64-apple-darwin', nativeFile],
  ]) {
    for (const pkg of selectedPackages(readJSON(file))) {
      if (!pkg.source?.startsWith('registry+')) {
        throw new Error(`Expected an unmodified registry package: ${pkg.id}`);
      }
      const existing = packages.get(pkg.id);
      if (existing) {
        assert.equal(existing.pkg.license, pkg.license, `License differs by target: ${pkg.id}`);
        existing.targets.push(target);
      } else {
        packages.set(pkg.id, { pkg, targets: [target] });
      }
    }
  }
  if (!packages.size) throw new Error('No resolved third-party packages');
  const documents = new Map();
  const sections = [];
  const ordered = [...packages.values()].sort((a, b) => {
    const x = `${a.pkg.name}@${a.pkg.version}`, y = `${b.pkg.name}@${b.pkg.version}`;
    return x < y ? -1 : x > y ? 1 : 0;
  });
  for (const { pkg, targets } of ordered) {
    const directory = path.dirname(pkg.manifest_path);
    const files = packageFiles(directory);
    const sourceURL = `https://static.crates.io/crates/${pkg.name}/${pkg.name}-${pkg.version}.crate`;
    const vcsFile = path.join(directory, '.cargo_vcs_info.json');
    const vcs = fs.existsSync(vcsFile) ? readJSON(vcsFile) : null;
    const repository = pkg.repository?.replace(/\/tree\/.*/, '').replace(/\/$/, '');
    const revision = vcs?.git?.sha1;
    const texts = files.filter(file =>
      /^(licen[cs]e|copying|copyright|notice)([._-]|$)/i.test(path.basename(file)) ||
      (pkg.license_file && path.resolve(directory, pkg.license_file) === file)
    ).map(file => ({
      label: `Published crate: ${path.relative(directory, file)}`,
      bytes: fs.readFileSync(file),
    }));
    const fallback = provenance.find(input => input.packages.includes(`${pkg.name}@${pkg.version}`));
    if (fallback) {
      assert.equal(fallback.license, pkg.license, `Fallback license mismatch: ${pkg.id}`);
      assert.equal(fallback.repository, repository, `Fallback repository mismatch: ${pkg.id}`);
      assert.equal(fallback.revision, revision, `Fallback source revision mismatch: ${pkg.id}`);
      assert.equal(path.basename(fallback.file), fallback.file, 'Invalid fallback file name');
      const bytes = fs.readFileSync(path.join(licenseDirectory, fallback.file));
      assert.equal(hash(bytes), fallback.sha256, `Upstream license checksum mismatch: ${fallback.file}`);
      texts.push({ label: `Canonical upstream text: ${fallback.url}`, bytes });
    }
    let distributionLicense;
    try {
      distributionLicense = requireLicenseTexts(pkg.license, texts.map(text => text.bytes.toString('utf8')));
    } catch (error) {
      throw new Error(`${pkg.name}@${pkg.version}: ${error.message}`);
    }
    const lines = [
      `${pkg.name} ${pkg.version}`,
      `Declared license: ${pkg.license}`,
      `Distribution license: ${distributionLicense}`,
      'Changes by Notify: none (unmodified published dependency).',
      `Target dependency graphs: ${targets.join(', ')}`,
      `Package authors (upstream metadata): ${pkg.authors?.join('; ') || 'Not specified'}`,
      `Published source download: ${sourceURL}`,
      `Upstream repository: ${pkg.repository || 'Not specified'}`,
    ];
    if (revision) {
      assert.match(revision, /^[a-f0-9]{40}$/, `Invalid source revision: ${pkg.id}`);
      lines.push(`Upstream source revision: ${revision}`);
      if (/^https:\/\/github\.com\/[^/]+\/[^/]+$/.test(repository)) {
        lines.push(`Source tree: ${repository}/tree/${revision}/${vcs.path_in_vcs || ''}`);
        lines.push(`Upstream source archive: ${repository}/archive/${revision}.tar.gz`);
      }
    }
    if (pkg.license === 'MPL-2.0') {
      if (!revision || !repository) throw new Error(`Missing MPL source provenance: ${pkg.id}`);
      lines.push(
        'MPL source availability: the Source Code Form of this unmodified component',
        'is available under MPL-2.0 from the exact-version published source download',
        'and the pinned upstream source archive above. The latter includes the workspace',
        'build manifests. You may obtain, modify and distribute that source under MPL-2.0.',
      );
      const copyrightFiles = files.filter(file =>
        /\.(rs|c|h|md|txt|toml)$/i.test(file) && /copyright|©/i.test(fs.readFileSync(file, 'utf8')));
      if (copyrightFiles.length) {
        // Do not invent or truncate newly introduced source-level notices.
        throw new Error(`Review MPL source copyright notices before packaging: ${copyrightFiles.join(', ')}`);
      }
      lines.push('Copyright notices: no explicit copyright statement occurs in this published',
        'package; author attribution above is from Cargo metadata, not an inferred copyright.');
    }
    for (const { label, bytes } of texts) {
      const id = hash(bytes);
      documents.set(id, bytes.toString('utf8'));
      lines.push(`License/notice document SHA-256 ${id} — ${label}`);
    }
    sections.push(lines.join('\n'));
  }
  const output = [
    'NOTIFY REMOTE CRYPTO — THIRD-PARTY LICENSE AND SOURCE NOTICES',
    '',
    'Generated by scripts/remote-crypto-notices.mjs from locked, target-filtered',
    'Cargo metadata for wasm32-unknown-unknown and aarch64-apple-darwin.',
    `Coverage: ${packages.size} distinct third-party package/version entries, unioned`,
    'from the reachable normal and build dependency graphs (including proc macros).',
    'Dev-only and unreachable optional packages are excluded. Build-time packages',
    'are included conservatively; graph membership does not assert that every',
    'package contributes code to either final executable.',
    'This covers the Notify Rust/OpenMLS native helper and browser WASM crate',
    'dependencies, not a whole-application, Rust toolchain, or system-library inventory.',
    '',
    'All listed dependencies are distributed without Notify modifications.',
    'Where offered, MIT is the selected license alternative; additional AND terms',
    'remain applicable. All available package license, copyright and notice files',
    'are reproduced below, including alternative license texts where supplied.',
    'Missing package license files are supplemented only by recorded upstream',
    'texts. Identical documents are reproduced once and referenced by SHA-256.',
    'MPL-covered components have exact-version source download information below.',
    'These are distribution notices, not legal certification.',
    '',
    'PACKAGE INDEX',
    '=============',
    '',
    sections.join('\n\n' + '-'.repeat(78) + '\n\n'),
    '',
    'FULL LICENSE AND NOTICE DOCUMENTS',
    '=================================',
    '',
    [...documents].map(([id, text]) => `DOCUMENT SHA-256 ${id}\n\n${text}`).join('\n\n' + '='.repeat(78) + '\n\n'),
    '',
  ].join('\n');
  const nativeOutput = path.join(root, 'crypto/THIRD-PARTY-NOTICES.txt');
  for (const file of [nativeOutput, path.resolve(mobileOutput)]) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, output);
  }
  console.log(`Wrote identical notices: ${packages.size} packages, ${documents.size} documents, ${Buffer.byteLength(output)} bytes`);
  console.log(nativeOutput);
  console.log(path.resolve(mobileOutput));
}

function selfTest() {
  const metadata = {
    packages: ['root', 'runtime', 'build', 'unused', 'dev'].map(id => ({ id })),
    resolve: {
      root: 'root',
      nodes: [
        { id: 'root', deps: [
          { pkg: 'runtime', dep_kinds: [{ kind: null }] },
          { pkg: 'build', dep_kinds: [{ kind: 'build' }] },
          { pkg: 'dev', dep_kinds: [{ kind: 'dev' }] },
        ] },
        ...['runtime', 'build', 'unused', 'dev'].map(id => ({ id, deps: [] })),
      ],
    },
  };
  assert.deepEqual(selectedPackages(metadata).map(p => p.id), ['runtime', 'build']);
  assert.throws(() => selectedPackages({ ...metadata, resolve: null }), /resolve/);
  assert.throws(() => requireLicenseTexts('MPL-2.0', []), /Missing.*MPL-2.0/);
  assert.throws(() => requireLicenseTexts('Unrecognized', ['some text']), /Unsupported/);
  assert.throws(() => requireLicenseTexts('(MIT OR Apache-2.0) AND Unicode-3.0',
    ['Permission is hereby granted, free of charge. The above copyright notice and this permission notice. SOFTWARE IS PROVIDED.' + ' '.repeat(800)]),
  /Missing.*Unicode-3.0/);
  assert.equal(requireLicenseTexts('MIT OR Apache-2.0',
    ['Permission is hereby granted, free of charge. The above copyright notice and this permission notice. SOFTWARE IS PROVIDED.' + ' '.repeat(800)]), 'MIT');
  const broken = structuredClone(metadata);
  broken.resolve.nodes = broken.resolve.nodes.filter(node => node.id !== 'runtime');
  assert.throws(() => selectedPackages(broken), /Missing resolve node/);
  console.log('remote-crypto-notices self-test passed');
}

try {
  if (process.argv.length === 3 && process.argv[2] === '--self-test') selfTest();
  else if (process.argv.length === 5) generate(...process.argv.slice(2));
  else throw new Error('Usage: node scripts/remote-crypto-notices.mjs <wasm-metadata.json> <native-metadata.json> <mobile-LICENSES.txt>\n       node scripts/remote-crypto-notices.mjs --self-test');
} catch (error) {
  console.error(`remote-crypto-notices: ${error.message}`);
  process.exitCode = 1;
}
