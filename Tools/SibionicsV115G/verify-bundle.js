"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const bundlePath = path.resolve(
  __dirname,
  "../../xDrip/BluetoothTransmitter/CGM/Sibionics/Resources/sibionics-v115g.js"
);
const expectedBundleHash = "EE90A78C0D32A672CAFF9E416D9C9D1B866D9C04354B61CD154674112E75A799";
const expectedOutputHash = "76426F289B2DAF92770910BD7EBDB6FA561E1F437E30382FB05B86D1A27DDDE0";

const bundleHash = crypto.createHash("sha256").update(fs.readFileSync(bundlePath)).digest("hex").toUpperCase();
if (bundleHash !== expectedBundleHash) {
  throw new Error(`bundle SHA-256 mismatch: ${bundleHash}`);
}

const root = require(bundlePath);
const api = root.tk.glucodata.drivers.sibionics.SibionicsV115G;

function sample(index) {
  return {
    raw: 7.4 + 1.7 * Math.sin(index / 37.0) + 0.45 * Math.cos(index / 11.0) + ((index % 29) - 14) * 0.006,
    temperature: 33.5 + 2.1 * Math.sin(index / 83.0) + 0.3 * Math.cos(index / 17.0),
    live: index % 17 === 0,
  };
}

function run(from, through) {
  const outputs = [];
  for (let index = from; index <= through; index += 1) {
    const value = sample(index);
    outputs.push(api.process(value.raw, value.temperature, index, value.live));
  }
  return outputs;
}

const sensitivity = 1.4;
const split = 1577;
const count = 3153;
api.reset(sensitivity);
const firstHalf = run(1, split);
const snapshot = api.snapshotHex();
const expectedTail = run(split + 1, count);

api.reset(sensitivity);
if (!api.restoreHex(snapshot)) {
  throw new Error("snapshot restore failed");
}
const restoredTail = run(split + 1, count);
if (expectedTail.length !== restoredTail.length || expectedTail.some((value, index) => !Object.is(value, restoredTail[index]))) {
  throw new Error("snapshot continuation differs from uninterrupted output");
}

const digest = crypto.createHash("sha256");
for (const value of firstHalf.concat(expectedTail)) {
  const bytes = Buffer.allocUnsafe(8);
  bytes.writeDoubleLE(value);
  digest.update(bytes);
}
const outputHash = digest.digest("hex").toUpperCase();
if (outputHash !== expectedOutputHash) {
  throw new Error(`output vector SHA-256 mismatch: ${outputHash}`);
}

console.log(`bundle_sha256=${bundleHash}`);
console.log(`samples=${count} snapshot_restore=ok snapshot_hex_chars=${snapshot.length}`);
console.log(`output_vector_sha256=${outputHash}`);
