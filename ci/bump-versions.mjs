#!/usr/bin/env node
// Check or update every pinned dependency, with checksums, in one place.
//
//   node ci/bump-versions.mjs                 # report only (default)
//   node ci/bump-versions.mjs --write         # rewrite pins in place
//   node ci/bump-versions.mjs --only bun,uv   # limit to some components
//   node ci/bump-versions.mjs --min-age-days 7
//   node ci/bump-versions.mjs --fail-on-updates   # exit 2 when updates exist
//
// Components: bun uv herdr-core ovis agents base-image ci-tools actions
// Releases newer than --min-age-days (default 14) are skipped as a basic
// supply-chain precaution. Nothing is built or tested here: after --write,
// rebuild and run both smoke suites (ci/build.sh, ci/test.sh) before merging.
//
// Set LUCOA_GITHUB_API_TOKEN to avoid GitHub's anonymous rate limit. GITHUB_TOKEN
// is deliberately ignored: on Forgejo it is a Forgejo credential.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, appendFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const write = flag('--write');
const minAgeDays = Number(option('--min-age-days', '14'));
const only = option('--only', '').split(',').filter(Boolean);
const cutoff = Date.now() - minAgeDays * 86_400_000;
const userAgent = 'lucoa-bump-versions';

// ---------- helpers ----------
async function http(url, { headers = {}, method = 'GET' } = {}) {
  const response = await fetch(url, { method, headers: { 'user-agent': userAgent, ...headers } });
  if (!response.ok) throw new Error(`${method} ${url}: HTTP ${response.status}`);
  return response;
}
const json = async (url, headers) => (await http(url, { headers })).json();
function github(path) {
  const headers = { accept: 'application/vnd.github+json' };
  if (process.env.LUCOA_GITHUB_API_TOKEN) headers.authorization = `Bearer ${process.env.LUCOA_GITHUB_API_TOKEN}`;
  return json(`https://api.github.com/${path}`, headers);
}
async function sha256Of(url) {
  const body = Buffer.from(await (await http(url)).arrayBuffer());
  return createHash('sha256').update(body).digest('hex');
}
const old = (date) => Date.parse(date) <= cutoff;

// Highest-versioned stable GitHub release at least minAgeDays old.
async function githubRelease(repo, tagPattern = /^v?\d+\.\d+\.\d+$/) {
  const releases = await github(`repos/${repo}/releases?per_page=100`);
  const release = releases
    .filter((r) => !r.draft && !r.prerelease && tagPattern.test(r.tag_name) && old(r.published_at))
    .sort((a, b) => compareSemver(a.tag_name, b.tag_name))
    .at(-1);
  if (!release) throw new Error(`${repo}: no stable release older than ${minAgeDays} days`);
  return release;
}
function assetDigest(release, name) {
  const asset = release.assets.find((a) => a.name === name);
  if (!asset?.digest?.startsWith('sha256:')) throw new Error(`${release.tag_name}: no sha256 digest for ${name}`);
  return asset.digest.slice('sha256:'.length);
}
function lsRemoteTag(url, tag) {
  const out = execFileSync('git', ['ls-remote', url, `refs/tags/${tag}`, `refs/tags/${tag}^{}`], { encoding: 'utf8' });
  const lines = out.trim().split('\n').filter(Boolean).map((l) => l.split('\t'));
  const peeled = lines.find(([, ref]) => ref.endsWith('^{}')) ?? lines[0];
  if (!peeled) throw new Error(`${url}: tag ${tag} not found`);
  return peeled[0];
}

class EnvFile {
  constructor(path) { this.path = join(root, path); this.text = readFileSync(this.path, 'utf8'); }
  get(key) {
    const m = this.text.match(new RegExp(`^${key}=(.*)$`, 'm'));
    if (!m) throw new Error(`${this.path}: missing ${key}`);
    return m[1];
  }
  set(key, value) { this.text = this.text.replace(new RegExp(`^${key}=.*$`, 'm'), `${key}=${value}`); }
  save() { writeFileSync(this.path, this.text); }
}

const results = [];
const pendingWrites = [];
function record(component, current, latest, apply) {
  // Never downgrade: a pin may be newer than the age cutoff allows.
  const semver = /\d+\.\d+\.\d+/;
  const changed = semver.test(current) && semver.test(latest)
    ? compareSemver(latest, current) > 0
    : current !== latest;
  if (!changed) latest = current;
  results.push({ component, current, latest, changed });
  // Apply callbacks may be async (the Ovis tarball checksum).
  if (changed && write) pendingWrites.push(Promise.resolve(apply()));
}

// ---------- components ----------
const versions = new EnvFile('build/versions.env');
const tools = new EnvFile('ci/tools.env');

const components = {
  async bun() {
    const release = await githubRelease('oven-sh/bun', /^bun-v\d+\.\d+\.\d+$/);
    const version = release.tag_name.replace(/^bun-v/, '');
    record('bun', versions.get('BUN_VERSION'), version, () => {
      versions.set('BUN_VERSION', version);
      versions.set('BUN_X64_SHA256', assetDigest(release, 'bun-linux-x64-baseline.zip'));
      versions.set('BUN_ARM64_SHA256', assetDigest(release, 'bun-linux-aarch64.zip'));
    });
  },

  async uv() {
    const release = await githubRelease('astral-sh/uv');
    const version = release.tag_name;
    record('uv', versions.get('UV_VERSION'), version, () => {
      versions.set('UV_VERSION', version);
      versions.set('UV_X64_SHA256', assetDigest(release, 'uv-x86_64-unknown-linux-gnu.tar.gz'));
      versions.set('UV_ARM64_SHA256', assetDigest(release, 'uv-aarch64-unknown-linux-gnu.tar.gz'));
    });
  },

  async 'herdr-core'() {
    const manifest = await json('https://releases.herdr.dev/core/latest.json');
    // Ovis's herdr-core adapter speaks protocol generation 1.
    if (manifest.generation !== 1) {
      throw new Error(`herdr-core ${manifest.version} uses protocol generation ${manifest.generation}; check Ovis compatibility by hand`);
    }
    const x64 = manifest.targets['linux-x86_64'];
    const published = (await http(x64.url, { method: 'HEAD' })).headers.get('last-modified');
    const current = versions.get('HC_VERSION');
    if (published && !old(published) && manifest.version !== current) {
      results.push({ component: 'herdr-core', current, latest: `${manifest.version} (too new, skipped)`, changed: false });
      return;
    }
    record('herdr-core', current, manifest.version, () => {
      versions.set('HC_VERSION', manifest.version);
      versions.set('HC_X64_SHA256', x64.sha256);
      versions.set('HC_ARM64_SHA256', manifest.targets['linux-aarch64'].sha256);
    });
  },

  async ovis() {
    const release = await githubRelease('devswha/ovis');
    const version = release.tag_name.replace(/^v/, '');
    const current = versions.get('OVIS_VERSION');
    let note = '';
    if (version !== current) {
      const revision = lsRemoteTag('https://github.com/devswha/ovis', release.tag_name);
      const pkg = await json(`https://raw.githubusercontent.com/devswha/ovis/${revision}/package.json`);
      const bun = (pkg.packageManager ?? '').replace(/^bun@/, '');
      if (bun && bun !== versions.get('BUN_VERSION')) note = ` (declares bun ${bun})`;
      record('ovis', current, version, () => {
        versions.set('OVIS_VERSION', version);
        versions.set('OVIS_REVISION', revision);
        return sha256Of(`https://codeload.github.com/devswha/ovis/tar.gz/${revision}`)
          .then((sum) => versions.set('OVIS_SHA256', sum));
      });
      if (results.at(-1).changed) results.at(-1).latest += note;
    } else {
      record('ovis', current, version, () => {});
    }
  },

  async agents() {
    const pkgPath = join(root, 'build/agents/package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    let changed = false;
    for (const name of Object.keys(pkg.dependencies)) {
      const doc = await json(`https://registry.npmjs.org/${name.replace('/', '%2f')}`);
      const latest = doc['dist-tags'].latest;
      const candidates = Object.keys(doc.time)
        .filter((v) => /^\d+\.\d+\.\d+$/.test(v) && old(doc.time[v]) && !doc.versions[v]?.deprecated)
        .sort(compareSemver);
      const pick = candidates.filter((v) => compareSemver(v, latest) <= 0).at(-1);
      if (!pick) continue;
      record(name, pkg.dependencies[name], pick, () => { pkg.dependencies[name] = pick; changed = true; });
    }
    if (changed) {
      writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);
      // Lockfile only: no install scripts run on the maintainer's machine.
      execFileSync('npm', ['install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'],
        { cwd: join(root, 'build/agents'), stdio: 'inherit' });
    }
  },

  async 'base-image'() {
    const dockerfile = join(root, 'Dockerfile');
    let text = readFileSync(dockerfile, 'utf8');
    const m = text.match(/^FROM node:(26-trixie-slim)@(sha256:[0-9a-f]{64})/m);
    if (!m) throw new Error('Dockerfile: digest-pinned node:26-trixie-slim FROM line not found');
    const { token } = await json('https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/node:pull');
    const response = await http(`https://registry-1.docker.io/v2/library/node/manifests/${m[1]}`, {
      method: 'HEAD',
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json',
      },
    });
    const digest = response.headers.get('docker-content-digest');
    if (!digest?.startsWith('sha256:')) throw new Error('Docker Hub did not return an index digest');
    record(`node:${m[1]}`, m[2].slice(0, 19), digest.slice(0, 19), () => {
      const today = new Date().toISOString().slice(0, 10);
      text = text.replace(m[2], digest).replace(/(index, reviewed )\d{4}-\d{2}-\d{2}/, `$1${today}`);
      writeFileSync(dockerfile, text);
    });
  },

  async 'ci-tools'() {
    const specs = [
      ['SHELLCHECK', 'koalaman/shellcheck', (v) => `shellcheck-${v}.linux.x86_64.tar.gz`],
      ['HADOLINT', 'hadolint/hadolint', () => 'hadolint-linux-x86_64'],
      ['TRIVY', 'aquasecurity/trivy', (v) => `trivy_${v.slice(1)}_Linux-64bit.tar.gz`],
      ['COSIGN', 'sigstore/cosign', () => 'cosign-linux-amd64'],
    ];
    for (const [key, repo, asset] of specs) {
      const release = await githubRelease(repo, /^v\d+\.\d+\.\d+$/);
      record(repo.split('/')[1], tools.get(`${key}_VERSION`), release.tag_name, () => {
        tools.set(`${key}_VERSION`, release.tag_name);
        tools.set(`${key}_SHA256`, assetDigest(release, asset(release.tag_name)));
      });
    }
  },

  async actions() {
    const files = ['.github/workflows', '.forgejo/workflows']
      .filter((dir) => existsSync(join(root, dir)))
      .flatMap((dir) => readdirSync(join(root, dir)).filter((f) => /\.ya?ml$/.test(f)).map((f) => join(root, dir, f)));
    const pattern = /uses: (https:\/\/data\.forgejo\.org\/)?actions\/([\w-]+)@([0-9a-f]{40}) # (v[\d.]+)/g;
    const seen = new Map();
    for (const file of files) {
      for (const [, , action, , tag] of readFileSync(file, 'utf8').matchAll(pattern)) seen.set(action, tag);
    }
    for (const [action, current] of seen) {
      const release = await githubRelease(`actions/${action}`, /^v\d+\.\d+\.\d+$/);
      const tag = release.tag_name;
      record(`actions/${action}`, current, tag, () => {
        const sha = lsRemoteTag(`https://github.com/actions/${action}`, tag);
        for (const file of files) {
          let text = readFileSync(file, 'utf8');
          const forgejoMirror = text.includes(`data.forgejo.org/actions/${action}@`);
          if (forgejoMirror && lsRemoteTag(`https://data.forgejo.org/actions/${action}`, tag) !== sha) {
            throw new Error(`data.forgejo.org mirror of actions/${action} ${tag} differs from GitHub; not updating`);
          }
          text = text.replace(new RegExp(`(actions/${action}@)[0-9a-f]{40} # v[\\d.]+`, 'g'), `$1${sha} # ${tag}`);
          writeFileSync(file, text);
        }
      });
    }
  },
};

function compareSemver(a, b) {
  const parse = (v) => v.match(/(\d+)\.(\d+)\.(\d+)/).slice(1).map(Number);
  const pa = parse(a);
  const pb = parse(b);
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
  return 0;
}

// ---------- main ----------
const selected = only.length ? only : Object.keys(components);
for (const name of selected) if (!components[name]) throw new Error(`unknown component: ${name}`);
const errors = [];
for (const name of selected) {
  try {
    await components[name]();
  } catch (error) {
    errors.push(`${name}: ${error.message}`);
  }
}
for (const outcome of await Promise.allSettled(pendingWrites)) {
  if (outcome.status === 'rejected') errors.push(outcome.reason.message);
}
// Never save half-updated pins (for example a version without its checksum).
if (write && !errors.length) { versions.save(); tools.save(); }

const lines = [
  `### Pinned dependencies (${write ? 'updated' : 'check only'}, min age ${minAgeDays} days)`, '',
  '| Component | Current | Available |', '| --- | --- | --- |',
  ...results.map((r) => `| ${r.component} | ${r.current} | ${r.changed ? `**${r.latest}**` : r.latest} |`),
  ...(errors.length ? ['', 'Errors:', ...errors.map((e) => `- ${e}`)] : []),
];
console.log(lines.join('\n'));
const summaryFile = process.env.GITHUB_STEP_SUMMARY;
if (summaryFile) appendFileSync(summaryFile, `${lines.join('\n')}\n`);
const updates = results.filter((r) => r.changed).length;
if (write && updates) console.log('\nRebuild and run ci/test.sh before committing these pins.');
if (errors.length) process.exitCode = 1;
else if (updates && flag('--fail-on-updates')) process.exitCode = 2;
