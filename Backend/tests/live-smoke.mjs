// Explicit opt-in: creates a disposable Auth user and metadata fixture in the real project.
// No local catalogs or media are read. The user and all fixture documents are removed in finally.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { initializeApp, deleteApp } from 'firebase/app';
import { getAuth, createUserWithEmailAndPassword, deleteUser, signOut, signInWithEmailAndPassword } from 'firebase/auth';
import { getFirestore, doc, setDoc, getDocFromServer, runTransaction, Bytes, serverTimestamp, terminate, writeBatch, deleteDoc } from 'firebase/firestore';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
if (process.env.FOLDERFLOW_LIVE_SMOKE !== 'folderflow-marco-2026') throw Error('Explicit project opt-in is required');
const projectId = 'folderflow-marco-2026';
const plist = new URL('../../Sources/FolderFlow/Resources/GoogleService-Info.plist', import.meta.url);
const apiKey = execFileSync('plutil', ['-extract','API_KEY','raw',fileURLToPath(plist)],{encoding:'utf8'}).trim();
const app = initializeApp({projectId,apiKey});
const auth = getAuth(app), db = getFirestore(app);
let user, secondApp, secondAuth, secondDb;
try {
  const email = `folderflow-smoke-${randomUUID()}@example.com`;
  const password = randomUUID()+'aA9!';
  user = (await createUserWithEmailAndPassword(auth,email,password)).user;
  const parent = doc(db,`users/${user.uid}/catalogs/${randomUUID()}`);
  const item = doc(parent,'projects',randomUUID());
  const value = () => ({revision:1,mutationID:randomUUID(),deleted:false,payload:Bytes.fromUint8Array(new TextEncoder().encode('{"fixture":true}')),updatedAt:serverTimestamp()});
  await runTransaction(db,async tx => {assert.equal((await tx.get(parent)).exists(),false);tx.set(parent,value());});
  await setDoc(item,value());
  assert.equal((await getDocFromServer(item)).data().revision,1);
  await assert.rejects(setDoc(item,value()),/permission/i);
  await assert.rejects(getDocFromServer(doc(db,'users/another-user/catalogs/private')),/permission/i);
  const preferencesPath = `users/${user.uid}/settings/preferences`;
  const preferences = doc(db,preferencesPath);
  const encoded = settings => Bytes.fromUint8Array(new TextEncoder().encode(JSON.stringify(settings)));
  await runTransaction(db,async tx => {
    assert.equal((await tx.get(preferences)).exists(),false);
    tx.set(preferences,{...value(),payload:encoded({launchAtLogin:true,hideDockIcon:false})});
  });
  secondApp = initializeApp({projectId,apiKey},'second-computer');
  secondAuth = getAuth(secondApp); secondDb = getFirestore(secondApp);
  await signInWithEmailAndPassword(secondAuth,email,password);
  const secondPreferences = doc(secondDb,preferencesPath);
  const fromFirst = (await getDocFromServer(secondPreferences)).data();
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromFirst.payload.toUint8Array())),{launchAtLogin:true,hideDockIcon:false});
  await runTransaction(secondDb,async tx => {
    assert.equal((await tx.get(secondPreferences)).data().revision,1);
    tx.set(secondPreferences,{...value(),revision:2,payload:encoded({launchAtLogin:false,hideDockIcon:true})});
  });
  const fromSecond = (await getDocFromServer(preferences)).data();
  assert.equal(fromSecond.revision,2);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromSecond.payload.toUint8Array())),{launchAtLogin:false,hideDockIcon:true});
  await assert.rejects(setDoc(preferences,{...value(),revision:2}),/permission/i);
  const backupRoot = doc(db,`users/${user.uid}/backups/${randomUUID()}`);
  const version = doc(backupRoot,'versions',randomUUID());
  const chunk = doc(version,'chunks','0');
  const backupBatch = writeBatch(db);
  backupBatch.set(backupRoot,{updatedAt:serverTimestamp()});
  backupBatch.set(version,{createdAt:serverTimestamp(),format:1,rawSize:100,compressedSize:3,chunkCount:1,checksum:'a'.repeat(64),projectCount:1});
  backupBatch.set(chunk,{index:0,payload:Bytes.fromUint8Array(new Uint8Array([1,2,3]))});
  await backupBatch.commit();
  assert.equal((await getDocFromServer(doc(secondDb,version.path))).data().projectCount,1);
  await assert.rejects(deleteDoc(version),/permission/i);
  await assert.rejects(deleteDoc(chunk),/permission/i);
  await assert.rejects(deleteDoc(parent),/permission/i);
  await assert.rejects(deleteDoc(item),/permission/i);
  assert.equal((await getDocFromServer(parent)).exists(),true);
  assert.equal((await getDocFromServer(item)).exists(),true);
  console.log('PASS live Auth, two preference clients, atomic backup chunks and protection of recent copies/live catalogs/projects');
} finally {
  if(user){
    // Admin cleanup uses the existing CLI session; no long-lived credential enters the app or output.
    execFileSync('npm',['exec','--yes','--package','firebase-tools','--','firebase','firestore:delete',`users/${user.uid}`,'--recursive','--force','--project',projectId],{stdio:'pipe'});
    await deleteUser(user);
    console.log('Removed temporary test account and catalog fixtures');
  }
  if(secondApp){ await signOut(secondAuth); await terminate(secondDb); await deleteApp(secondApp); }
  await signOut(auth); await terminate(db); await deleteApp(app);
}
