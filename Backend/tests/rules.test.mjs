import { readFile } from 'node:fs/promises';
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, deleteDoc, serverTimestamp, Bytes, runTransaction, writeBatch, Timestamp } from 'firebase/firestore';
let env;
const payload = () => ({payload: Bytes.fromUint8Array(new TextEncoder().encode('{"name":"Fixture"}')), revision: 1,
  mutationID: '11111111-1111-4111-8111-111111111111', deleted: false, updatedAt: serverTimestamp()});
before(async () => {
  env = await initializeTestEnvironment({projectId:'demo-folderflow', firestore:{host:'127.0.0.1',port:16880,
    rules:await readFile(new URL('../firestore.rules',import.meta.url),'utf8')}});
});
after(async () => { await env?.cleanup(); });
test('catalogs are private to the authenticated owner, including nonexistent document reads', async () => {
  const alice = env.authenticatedContext('alice').firestore();
  const bob = env.authenticatedContext('bob').firestore();
  const guest = env.unauthenticatedContext().firestore();
  const path = 'users/alice/catalogs/private';
  await assertSucceeds(getDoc(doc(alice,path)));
  await assertSucceeds(setDoc(doc(alice,path),payload()));
  await assertFails(getDoc(doc(bob,path)));
  await assertFails(getDoc(doc(guest,path)));
  await assertFails(setDoc(doc(bob,path),{...payload(),revision:2}));
  await assertFails(setDoc(doc(guest,'users/guest/catalogs/c'),payload()));
});
test('project creation requires a catalog and revisions must increase exactly once', async () => {
  const db = env.authenticatedContext('carol').firestore();
  const parent = doc(db,'users/carol/catalogs/studio');
  const item = doc(db,'users/carol/catalogs/studio/projects/project');
  await assertFails(setDoc(item,payload()));
  await assertSucceeds(setDoc(parent,payload()));
  await assertSucceeds(setDoc(item,payload()));
  await assertFails(setDoc(item,payload()));
  await assertSucceeds(setDoc(item,{...payload(),revision:2}));
  await assertFails(setDoc(item,{...payload(),revision:4}));
  await assertFails(deleteDoc(item));
  await assertSucceeds(setDoc(item,{...payload(),revision:3,deleted:true}));
});
test('invalid payloads and untrusted timestamps are rejected', async () => {
  const db = env.authenticatedContext('dave').firestore();
  await assertFails(setDoc(doc(db,'users/dave/catalogs/bad'),{...payload(),payload:'not-bytes'}));
  await assertFails(setDoc(doc(db,'users/dave/catalogs/time'),{...payload(),updatedAt:new Date(0)}));
  await assertFails(setDoc(doc(db,'users/dave/catalogs/large'),{...payload(),payload:Bytes.fromUint8Array(new Uint8Array(700000))}));
  await assertFails(setDoc(doc(db,'users/dave/catalogs/extra'),{...payload(),owner:'another-user'}));
});
test('the owner can create a catalog in a transaction that reads a missing document', async () => {
  const db = env.authenticatedContext('erin').firestore();
  const ref = doc(db,'users/erin/catalogs/new');
  await assertSucceeds(runTransaction(db,async tx => {
    const value = await tx.get(ref); assert.equal(value.exists(),false); tx.set(ref,payload());
  }));
});
test('account preferences are private and require consecutive revisions', async () => {
  const alice = env.authenticatedContext('preferences-alice').firestore();
  const bob = env.authenticatedContext('preferences-bob').firestore();
  const guest = env.unauthenticatedContext().firestore();
  const path = 'users/preferences-alice/settings/preferences';
  await assertSucceeds(getDoc(doc(alice,path)));
  await assertSucceeds(setDoc(doc(alice,path),payload()));
  await assertFails(getDoc(doc(bob,path)));
  await assertFails(getDoc(doc(guest,path)));
  await assertFails(setDoc(doc(bob,path),{...payload(),revision:2}));
  await assertFails(setDoc(doc(alice,path),payload()));
  await assertSucceeds(setDoc(doc(alice,path),{...payload(),revision:2}));
  await assertFails(setDoc(doc(alice,path),{...payload(),revision:3,deleted:true}));
  await assertFails(setDoc(doc(alice,'users/preferences-alice/settings/arbitrary'),payload()));
});

const backupHeader = () => ({createdAt:serverTimestamp(),format:1,rawSize:100,compressedSize:10,chunkCount:1,checksum:'a'.repeat(64),projectCount:1});
test('backup copies are private, immutable and cannot be deleted before sixty days', async () => {
 const db=env.authenticatedContext('backup-owner').firestore();
 const root=doc(db,'users/backup-owner/backups/catalog');
 const version=doc(root,'versions','launch'); const chunk=doc(version,'chunks','0');
 const batch=writeBatch(db);batch.set(root,{updatedAt:serverTimestamp()});batch.set(version,backupHeader());
 batch.set(chunk,{index:0,payload:Bytes.fromUint8Array(new Uint8Array([1,2,3]))});
 await assertSucceeds(batch.commit());
 await assertSucceeds(getDoc(version));
 const bob=env.authenticatedContext('backup-other').firestore();
 await assertFails(getDoc(doc(bob,version.path)));
 await assertFails(getDoc(doc(bob,chunk.path)));
 await assertFails(setDoc(version,backupHeader()));
 await assertFails(deleteDoc(version));await assertFails(deleteDoc(chunk));await assertFails(deleteDoc(root));
 await assertFails(setDoc(doc(root,'versions','forged'),{...backupHeader(),createdAt:Timestamp.fromMillis(0)}));
});
test('expiry deletes only backup versions and chunks, never the live catalog or projects', async () => {
 const db=env.authenticatedContext('expiry-owner').firestore();
 const catalog=doc(db,'users/expiry-owner/catalogs/keep');
 const project=doc(catalog,'projects','keep');
 const root=doc(db,'users/expiry-owner/backups/keep');
 const version=doc(root,'versions','old');const chunk=doc(version,'chunks','0');
 await env.withSecurityRulesDisabled(async context=>{
  const admin=context.firestore();const time=Timestamp.fromMillis(Date.now()-61*24*60*60*1000);
  await setDoc(doc(admin,catalog.path),{...payload(),updatedAt:time});
  await setDoc(doc(admin,project.path),{...payload(),updatedAt:time});
  await setDoc(doc(admin,root.path),{updatedAt:time});
  await setDoc(doc(admin,version.path),{...backupHeader(),createdAt:time});
  await setDoc(doc(admin,chunk.path),{index:0,payload:Bytes.fromUint8Array(new Uint8Array([1,2,3]))});
 });
 await assertFails(deleteDoc(catalog));await assertFails(deleteDoc(project));
 const batch=writeBatch(db);batch.delete(chunk);batch.delete(version);await assertSucceeds(batch.commit());
 assert.equal((await getDoc(catalog)).exists(),true);assert.equal((await getDoc(project)).exists(),true);
 assert.equal((await getDoc(version)).exists(),false);assert.equal((await getDoc(chunk)).exists(),false);
});
