/* PiDurableKit code mode worker: pi-codemode 1.4.0 */
"use strict";(()=>{var Pe=Object.defineProperty;var Oe=n=>{throw TypeError(n)};var ze=(n,e,t)=>e in n?Pe(n,e,{enumerable:!0,configurable:!0,writable:!0,value:t}):n[e]=t;var f=(n,e)=>Pe(n,"name",{value:e,configurable:!0});var H=(n,e,t)=>ze(n,typeof e!="symbol"?e+"":e,t),ae=(n,e,t)=>e.has(n)||Oe("Cannot "+t);var N=(n,e,t)=>(ae(n,e,"read from private field"),t?t.call(n):e.get(n)),M=(n,e,t)=>e.has(n)?Oe("Cannot add the same private member more than once"):e instanceof WeakSet?e.add(n):e.set(n,t),q=(n,e,t,r)=>(ae(n,e,"write to private field"),r?r.call(n,t):e.set(n,t),t),le=(n,e,t)=>(ae(n,e,"access private method"),t);var C=globalThis.__native,ce={};globalThis.__runtime=ce;var U=globalThis,pe=class pe{id;constructor(e){this.id=e}ref(){return this}unref(){return this}hasRef(){return!0}refresh(){return this}[Symbol.toPrimitive](){return this.id}};f(pe,"Timeout");var Q=pe,Je=1,ee=new Map;function We(n){if(n instanceof Q)return n.id;if(typeof n=="number")return n}f(We,"timerId");function Ne(n){let e=Number(n);return e>=1&&e<=2147483647?e:1}f(Ne,"nodeDelay");function ue(n,e,t,r){if(typeof n!="function")throw new TypeError("Timer callback must be a function");let s=Je++;return ee.set(s,{callback:n,args:t,interval:r?e:void 0}),C.setTimer(s,e),new Q(s)}f(ue,"schedule");function fe(n){let e=We(n);e===void 0||!ee.delete(e)||C.clearTimer(e)}f(fe,"clear");ce.fireTimer=(n=>{let e=ee.get(n);if(e!==void 0){e.interval===void 0?ee.delete(n):C.setTimer(n,e.interval);try{e.callback(...e.args)}catch(t){de(t)}}});U.setTimeout=(n,e,...t)=>ue(n,Ne(e),t,!1);U.setInterval=(n,e,...t)=>ue(n,Ne(e),t,!0);U.setImmediate=(n,...e)=>ue(n,0,e,!1);U.clearTimeout=fe;U.clearInterval=fe;U.clearImmediate=fe;U.queueMicrotask=n=>{Promise.resolve().then(n).catch(de)};function qe(n){if(typeof n=="string")return n;if(n instanceof Error)return n.stack?`${n.name}: ${n.message}
${n.stack}`:`${n.name}: ${n.message}`;if(typeof n=="bigint")return`${n}n`;if(typeof n=="function"||typeof n=="symbol"||n===void 0)return String(n);try{return JSON.stringify(n)??String(n)}catch{return String(n)}}f(qe,"describe");function D(n){return(...e)=>C.log(n,e.map(qe).join(" "))}f(D,"logger");U.console={debug:D("debug"),log:D("info"),info:D("info"),warn:D("warn"),error:D("error"),trace:D("debug"),dir:D("debug"),assert:f((n,...e)=>{n||D("error")("Assertion failed",...e)},"assert"),time:f(()=>{},"time"),timeEnd:f(()=>{},"timeEnd"),group:f(()=>{},"group"),groupEnd:f(()=>{},"groupEnd")};function de(n){C.log("error",`Uncaught ${qe(n)}`)}f(de,"reportError");U.reportError=de;function Ue(n){if(n===null||!ArrayBuffer.isView(n))throw new TypeError("Expected an integer typed array");if(n.byteLength>65536)throw new RangeError("Quota exceeded");return C.randomBytes(new Uint8Array(n.buffer,n.byteOffset,n.byteLength)),n}f(Ue,"getRandomValues");function Ve(){let n=Ue(new Uint8Array(16));n[6]=n[6]&15|64,n[8]=n[8]&63|128;let e=Array.from(n,t=>t.toString(16).padStart(2,"0")).join("");return`${e.slice(0,8)}-${e.slice(8,12)}-${e.slice(12,16)}-${e.slice(16,20)}-${e.slice(20)}`}f(Ve,"randomUUID");function Ge(n){return n instanceof ArrayBuffer?new Uint8Array(n):new Uint8Array(n.buffer,n.byteOffset,n.byteLength)}f(Ge,"bytesOf");var Xe={async digest(n,e){let t=(typeof n=="string"?n:n.name).toUpperCase();if(t!=="SHA-256")throw new DOMException(`Unsupported digest algorithm ${t}`,"NotSupportedError");let r=C.sha256(Ge(e));return r.buffer.slice(r.byteOffset,r.byteOffset+r.byteLength)}};U.crypto={getRandomValues:Ue,randomUUID:Ve,subtle:Xe};var Te=C.now();U.performance={timeOrigin:Te,now:f(()=>C.now()-Te,"now"),mark:f(()=>{},"mark"),measure:f(()=>{},"measure")};U.self=globalThis;var te=globalThis,X,he,we=class we{constructor(){M(this,X);H(this,"encoding","utf-8")}encode(e=""){let t=String(e),r=new Uint8Array(t.length*3),{written:s}=le(this,X,he).call(this,t,r);return r.slice(0,s)}encodeInto(e,t){return le(this,X,he).call(this,String(e),t)}};X=new WeakSet,he=f(function(e,t){let r=0,s=0,o=e.length;for(;r<o;){let i=e.charCodeAt(r),a=1;if(i>=55296&&i<=56319&&r+1<o){let u=e.charCodeAt(r+1);u>=56320&&u<=57343?(i=65536+(i-55296<<10)+(u-56320),a=2):i=65533}else i>=55296&&i<=57343&&(i=65533);let l=i<128?1:i<2048?2:i<65536?3:4;if(s+l>t.length)break;l===1?t[s++]=i:l===2?(t[s++]=192|i>>6,t[s++]=128|i&63):l===3?(t[s++]=224|i>>12,t[s++]=128|i>>6&63,t[s++]=128|i&63):(t[s++]=240|i>>18,t[s++]=128|i>>12&63,t[s++]=128|i>>6&63,t[s++]=128|i&63),r+=a}return{read:r,written:s}},"#encodeInto"),f(we,"TextEncoderPolyfill");var me=we;function Ke(n){if(n==null)return new Uint8Array(0);if(n instanceof Uint8Array)return n;if(n instanceof ArrayBuffer)return new Uint8Array(n);if(ArrayBuffer.isView(n))return new Uint8Array(n.buffer,n.byteOffset,n.byteLength);throw new TypeError("The provided value is not of type '(ArrayBuffer or ArrayBufferView)'")}f(Ke,"toBytes");var R,z,_e=class _e{constructor(e="utf-8",t={}){H(this,"encoding","utf-8");H(this,"fatal");H(this,"ignoreBOM");M(this,R,[]);M(this,z,!1);let r=String(e).trim().toLowerCase();if(r!=="utf-8"&&r!=="utf8"&&r!=="unicode-1-1-utf-8")throw new RangeError(`The encoding label provided ('${e}') is not supported.`);this.fatal=t.fatal===!0,this.ignoreBOM=t.ignoreBOM===!0}decode(e,t={}){let r=Ke(e),s;N(this,R).length>0?(s=new Uint8Array(N(this,R).length+r.length),s.set(N(this,R),0),s.set(r,N(this,R).length),q(this,R,[])):s=r;let o=t.stream===!0,i="",a=[],l=0,u=s.length,c=f(()=>{i+=String.fromCharCode.apply(null,a),a=[]},"flush"),d=f(()=>{if(this.fatal)throw new TypeError("The encoded data was not valid for encoding utf-8");a.push(65533)},"replacement");for(;l<u;){let p=s[l],_=0,m=0,y=128,E=191;if(p<128){a.push(p),l++,a.length>=8192&&c();continue}else if(p>=194&&p<=223)_=1,m=p&31;else if(p>=224&&p<=239)p===224&&(y=160),p===237&&(E=159),_=2,m=p&15;else if(p>=240&&p<=244)p===240&&(y=144),p===244&&(E=143),_=3,m=p&7;else{d(),l++;continue}if(l+_>=u){let g=!0;for(let h=1;l+h<u;h++){let x=s[l+h],v=h===1?y:128,O=h===1?E:191;if(x<v||x>O){g=!1;break}}if(g&&o){for(let h=l;h<u;h++)N(this,R).push(s[h]);break}if(g){d();break}}let k=1,S=!0;for(let g=1;g<=_;g++){let h=s[l+g],x=g===1?y:128,v=g===1?E:191;if(h===void 0||h<x||h>v){S=!1;break}m=m<<6|h&63,k++}if(!S){d(),l+=k;continue}l+=k,m>65535?(m-=65536,a.push(55296+(m>>10),56320+(m&1023))):a.push(m),a.length>=8192&&c()}if(c(),!N(this,z)&&i.length>0&&(q(this,z,!0),!this.ignoreBOM&&i.charCodeAt(0)===65279&&(i=i.slice(1))),!o&&(q(this,z,!1),N(this,R).length>0)){if(q(this,R,[]),this.fatal)throw new TypeError("The encoded data was not valid for encoding utf-8");i+="�"}return i}};R=new WeakMap,z=new WeakMap,f(_e,"TextDecoderPolyfill");var ge=_e;typeof te.TextEncoder!="function"&&(te.TextEncoder=me);typeof te.TextDecoder!="function"&&(te.TextDecoder=ge);var I=globalThis.WebAssembly;if(I!==void 0){let n=f(s=>new Promise((o,i)=>{try{o(s())}catch(a){i(a)}}),"settle"),e=f(s=>n(()=>new I.Module(s)),"compile"),t=f((s,o)=>n(()=>{if(s instanceof I.Module)return new I.Instance(s,o);let i=new I.Module(s);return{module:i,instance:new I.Instance(i,o)}}),"instantiate"),r=f(async s=>new Uint8Array(await(await s).arrayBuffer()),"bytesOf");I.compile=e,I.instantiate=t,I.compileStreaming=async s=>e(await r(s)),I.instantiateStreaming=async(s,o)=>t(await r(s),o)}function re(n){return n instanceof Error?n.message:String(n)}f(re,"errorMessage");function Re(n){return{clock_time_get(i,a,l){let u=n(),c=new DataView(u.buffer);if(i===0||i===1){let d=BigInt(Date.now())*1000000n;return c.setBigUint64(l,d,!0),0}return 52},fd_write(i,a,l,u){let c=n(),d=new DataView(c.buffer),p=new Uint8Array(c.buffer),_=0;if(i!==1&&i!==2)return 8;for(let m=0;m<l;m++){let y=d.getUint32(a+m*8,!0),E=d.getUint32(a+m*8+4,!0),k=p.slice(y,y+E),S=new TextDecoder().decode(k);i===1?typeof process<"u"&&process.stdout?process.stdout.write(S):console.log(S):typeof process<"u"&&process.stderr?process.stderr.write(S):console.error(S),_+=E}return d.setUint32(u,_,!0),0},fd_close(i){return 52},fd_fdstat_get(i,a){let l=n(),u=new DataView(l.buffer);return i===1||i===2?(u.setUint8(a,2),u.setUint16(a+2,0,!0),u.setBigUint64(a+8,0n,!0),u.setBigUint64(a+16,0n,!0),0):8},fd_seek(i,a,l,u){return 52},random_get(i,a){let l=n(),u=new Uint8Array(l.buffer,i,a);if(typeof crypto<"u"&&crypto.getRandomValues)crypto.getRandomValues(u);else for(let c=0;c<a;c++)u[c]=Math.floor(Math.random()*256);return 0}}}f(Re,"createWasiShim");var Qe=new TextDecoder;function et(n,e){let t=new Uint8Array(n.buffer),r=e;for(;t[r]!==0;)r++;if(r===e)return{};let s=Qe.decode(t.slice(e,r)),o={};for(let i of s.split(`
`)){let a=i.indexOf("=");a>0&&(o[i.slice(0,a)]=i.slice(a+1))}return o}f(et,"parseVersionString");function tt(n,e){let t=`qjs_ext_${n.name.replace(/-/g,"_")}_versions`,r=n.instance.exports[t];if(typeof r!="function")return;let s=r();if(s!==0)return et(e,s)}f(tt,"extractExtensionVersions");function L(n,e){let t=0,r=0;for(;e.value<n.length;){let s=n[e.value++];if(t|=(s&127)<<r,(s&128)===0)break;r+=7}return t}f(L,"readULEB128");function rt(n){let e=WebAssembly.Module.customSections(n,"dylink.0");if(e.length===0)return null;let t=new Uint8Array(e[0]),r={value:0},s={memorySize:0,memoryAlignment:0,tableSize:0,tableAlignment:0,needed:[]};for(;r.value<t.length;){let o=L(t,r),i=L(t,r),a=r.value+i;if(o===1)s.memorySize=L(t,r),s.memoryAlignment=L(t,r),s.tableSize=L(t,r),s.tableAlignment=L(t,r);else if(o===2){let l=L(t,r);for(let u=0;u<l;u++){let c=L(t,r),d=new TextDecoder().decode(t.slice(r.value,r.value+c));r.value+=c,s.needed.push(d)}}r.value=a}return s}f(rt,"parseDylink");async function ye(n,e,t,r,s,o){let i;n.wasm instanceof WebAssembly.Module?i=n.wasm:i=await WebAssembly.compile(n.wasm);let a=rt(i);if(!a)throw new Error(`Extension "${n.name}" is not a WASM shared library (missing dylink.0 section)`);let l=e.memory,u=e.__indirect_function_table,c=e.__stack_pointer,d=e.malloc;if(!l)throw new Error("Main module does not export memory");if(!u)throw new Error("Main module does not export __indirect_function_table");if(!d)throw new Error("Main module does not export malloc");let p,_;if(o)p=o.memoryBase,_=o.tableBase;else if(a.memorySize>0){if(p=d(a.memorySize),p===0)throw new Error(`Failed to allocate ${a.memorySize} bytes for extension "${n.name}"`);new Uint8Array(l.buffer,p,a.memorySize).fill(0)}else p=0;o?(_=o.tableBase,_+a.tableSize>u.length&&u.grow(_+a.tableSize-u.length)):(_=u.length,a.tableSize>0&&u.grow(a.tableSize));let m=WebAssembly.Module.imports(i),y={env:{},"GOT.mem":{},"GOT.func":{}};if(m.some(w=>w.module==="wasi_snapshot_preview1")){let w=n.wasi&&s?n.wasi(s):void 0;y.wasi_snapshot_preview1={...t,...w,...r}}let k=new Set(WebAssembly.Module.exports(i).filter(w=>w.kind==="function").map(w=>w.name)),S=new Set;for(let w of m)if(w.module==="env"){if(w.name==="memory"&&w.kind==="memory")y.env.memory=l;else if(w.name==="__indirect_function_table"&&w.kind==="table")y.env.__indirect_function_table=u;else if(w.name==="__memory_base"&&w.kind==="global")y.env.__memory_base=new WebAssembly.Global({value:"i32",mutable:!1},p);else if(w.name==="__table_base"&&w.kind==="global")y.env.__table_base=new WebAssembly.Global({value:"i32",mutable:!1},_);else if(w.name==="__stack_pointer"&&w.kind==="global")y.env.__stack_pointer=c;else if(w.kind==="function"){let j=e[w.name];j&&typeof j=="function"?y.env[w.name]=j:(S.add(w.name),y.env[w.name]=()=>{throw new Error(`Extension "${n.name}" called unresolved symbol: env.${w.name}`)})}else if(w.kind==="global"){let j=e[w.name];j instanceof WebAssembly.Global?y.env[w.name]=j:y.env[w.name]=new WebAssembly.Global({value:"i32",mutable:!0},0)}}else if(w.module==="GOT.mem"&&w.kind==="global")y["GOT.mem"][w.name]=new WebAssembly.Global({value:"i32",mutable:!0},0);else if(w.module==="GOT.func"&&w.kind==="global"){let j=e[w.name];if(j&&typeof j=="function"){let Z=u.length;u.grow(1),u.set(Z,j),y["GOT.func"][w.name]=new WebAssembly.Global({value:"i32",mutable:!0},Z)}else y["GOT.func"][w.name]=new WebAssembly.Global({value:"i32",mutable:!0},0)}let g=[...S].filter(w=>k.has(w)),h={};for(let w of g){let j={target:null};h[w]=j,y.env[w]=(...Z)=>{if(!j.target)throw new Error(`Extension "${n.name}" called unresolved symbol during init: env.${w}`);return j.target(...Z)}}let x=await WebAssembly.instantiate(i,y),v=x.exports;for(let w of g){let j=v[w];typeof j=="function"&&(h[w].target=j)}typeof v.__wasm_apply_data_relocs=="function"&&v.__wasm_apply_data_relocs(),typeof v.__wasm_call_ctors=="function"&&v.__wasm_call_ctors();let O=n.initFn??`qjs_ext_${n.name.replace(/-/g,"_")}_init`,T={name:n.name,module:i,instance:x,dylink:a,memoryBase:p,tableBase:_,initFn:O};return T.versions=tt(T,l),T}f(ye,"loadExtension");function Ce(n,e){let t=n.instance.exports[n.initFn];if(typeof t!="function")throw new Error(`Extension "${n.name}" does not export init function "${n.initFn}"`);let r=e.qjs_get_context_ptr(),s=e.qjs_get_runtime_ptr(),o=t(r,s);if(o!==0)throw new Error(`Extension "${n.name}" init function returned error code ${o}`)}f(Ce,"initExtension");async function Ie(n,e,t,r,s,o){let i=[];for(let a of e){let l=n.find(c=>c.name===a.name);if(!l)throw new Error(`Extension "${a.name}" required by snapshot but not provided`);let u=await ye(l,t,r,s,o,{memoryBase:a.memoryBase,tableBase:a.tableBase});u.initFn=a.initFn,i.push(u)}return i}f(Ie,"restoreExtensions");var Be="3.6.2";var F=function(n,e,t){if(e!=null){if(typeof e!="object"&&typeof e!="function")throw new TypeError("Object expected.");var r,s;if(t){if(!Symbol.asyncDispose)throw new TypeError("Symbol.asyncDispose is not defined.");r=e[Symbol.asyncDispose]}if(r===void 0){if(!Symbol.dispose)throw new TypeError("Symbol.dispose is not defined.");r=e[Symbol.dispose],t&&(s=r)}if(typeof r!="function")throw new TypeError("Object not disposable.");s&&(r=f(function(){try{s.call(this)}catch(o){return Promise.reject(o)}},"dispose")),n.stack.push({value:e,dispose:r,async:t})}else t&&n.stack.push({async:!0});return e},$=(function(n){return function(e){function t(i){e.error=e.hasError?new n(i,e.error,"An error was suppressed during disposal."):i,e.hasError=!0}f(t,"fail");var r,s=0;function o(){for(;r=e.stack.pop();)try{if(!r.async&&s===1)return s=0,e.stack.push(r),Promise.resolve().then(o);if(r.dispose){var i=r.dispose.call(r.value);if(r.async)return s|=2,Promise.resolve(i).then(o,function(a){return t(a),o()})}else s|=1}catch(a){t(a)}if(s===1)return e.hasError?Promise.reject(e.error):Promise.resolve();if(e.hasError)throw e.error}return f(o,"next"),o()}})(typeof SuppressedError=="function"?SuppressedError:function(n,e,t){var r=new Error(t);return r.name="SuppressedError",r.error=n,r.suppressed=e,r}),ne=512*1024;var Se={DATE:1,EVAL:2,REGEXP:4,JSON:8,PROXY:16,MAP_SET:32,TYPED_ARRAYS:64,PROMISE:128,BIG_INT:256,WEAK_REF:512,PERFORMANCE:1024,DOM_EXCEPTION:2048,ATOB_BTOA:4096,ALL:4294967295},be=1363825491,xe=2,se=24,P=class P{exports;module;instance;encoder=new TextEncoder;decoder=new TextDecoder;disposed=!1;hostCallbacks=new Map;nextInternalId=1;interruptHandler=null;unhandledRejectionHandler=null;moduleNormalizeHandler=null;moduleLoadHandler=null;timezoneOffsetHandler=null;_global=null;_versions=null;_undefined=null;_null=null;_true=null;_false=null;_ownedHandles=new Set;_activeScope=null;loadedExtensions=[];constructor(e){this.module=e,this.instance=null,this.exports=null}setInstance(e){this.instance=e,this.exports=e.exports}get versions(){if(this.assertNotDisposed(),!this._versions){let e={"quickjs-wasi":Be,quickjs:this.readCString(this.exports.qjs_get_quickjs_version())};for(let t of this.loadedExtensions)t.versions&&Object.assign(e,t.versions);this._versions=e}return this._versions}get global(){return this._global||(this._global=new b(this,this.exports.qjs_get_global(),!0)),this._global}get undefined(){return this._undefined||(this._undefined=new b(this,this.exports.qjs_get_undefined(),!0)),this._undefined}get null(){return this._null||(this._null=new b(this,this.exports.qjs_get_null(),!0)),this._null}get true(){return this._true||(this._true=new b(this,this.exports.qjs_get_true(),!0)),this._true}get false(){return this._false||(this._false=new b(this,this.exports.qjs_get_false(),!0)),this._false}static async create(e){let t=P.normalizeOptions(e),r=await P.resolveModule(t.wasm),s=new P(r),{instance:o,wasiBuiltins:i,wasiUserOverrides:a,memoryProxy:l}=await P.instantiate(r,s,t.wasi);if(s.setInstance(o),s.exports._initialize(),(t.intrinsics!==void 0?s.exports.qjs_init2(t.intrinsics):s.exports.qjs_init())!==0)throw new Error("Failed to initialize QuickJS runtime");if(t.extensions){let c=o.exports;for(let d of t.extensions){let p=await ye(d,c,i,a,l);s.loadedExtensions.push(p),Ce(p,c)}}return P.applyLimits(s,t),s}static async restore(e,t){let r=P.normalizeOptions(t),s=await P.resolveModule(r.wasm),o=new P(s),{instance:i,wasiBuiltins:a,wasiUserOverrides:l,memoryProxy:u}=await P.instantiate(s,o,r.wasi);o.setInstance(i);let c=i.exports,d=o.exports.memory,p=d.buffer.byteLength/65536,_=Math.ceil(e.memory.byteLength/65536);if(_>p&&d.grow(_-p),e.extensions.length>0){let y=r.extensions??[];o.loadedExtensions=await Ie(y,e.extensions,c,a,l,u)}return new Uint8Array(d.buffer).set(e.memory),o.exports.qjs_set_runtime_and_context(e.runtimePtr,e.contextPtr),o.exports.__stack_pointer.value=e.stackPointer,P.applyLimits(o,r),o}static serializeSnapshot(e){let t=new TextEncoder,r=4,s=[],o=[];for(let d of e.extensions){let p=t.encode(d.name),_=t.encode(d.initFn);s.push(p),o.push(_),r+=4+p.length+4+4+4+_.length}let i=se+r+e.memory.byteLength,a=new ArrayBuffer(i),l=new DataView(a),u=new Uint8Array(a);l.setUint32(0,be,!1),l.setUint8(4,xe),l.setUint32(8,e.memory.byteLength,!0),l.setUint32(12,e.stackPointer,!0),l.setUint32(16,e.runtimePtr,!0),l.setUint32(20,e.contextPtr,!0);let c=se;l.setUint32(c,e.extensions.length,!0),c+=4;for(let d=0;d<e.extensions.length;d++){let p=e.extensions[d],_=s[d],m=o[d];l.setUint32(c,_.length,!0),c+=4,u.set(_,c),c+=_.length,l.setUint32(c,p.memoryBase,!0),c+=4,l.setUint32(c,p.tableBase,!0),c+=4,l.setUint32(c,m.length,!0),c+=4,u.set(m,c),c+=m.length}return u.set(e.memory,c),u}static deserializeSnapshot(e){if(e.length<se)throw new Error("Invalid snapshot: too small");let t=new DataView(e.buffer,e.byteOffset,e.byteLength),r=t.getUint32(0,!1);if(r!==be)throw new Error(`Invalid snapshot: bad magic (expected 0x${be.toString(16)}, got 0x${r.toString(16)})`);let s=t.getUint8(4);if(s!==xe&&s!==1)throw new Error(`Unsupported snapshot version: ${s} (expected ${xe})`);let o=t.getUint32(8,!0),i=t.getUint32(12,!0),a=t.getUint32(16,!0),l=t.getUint32(20,!0),u=[],c=se;if(s>=2){let _=t.getUint32(24,!0),m=28,y=new TextDecoder;for(let E=0;E<_;E++){let k=t.getUint32(m,!0);m+=4;let S=y.decode(e.slice(m,m+k));m+=k;let g=t.getUint32(m,!0);m+=4;let h=t.getUint32(m,!0);m+=4;let x=t.getUint32(m,!0);m+=4;let v=y.decode(e.slice(m,m+x));m+=x,u.push({name:S,memoryBase:g,tableBase:h,initFn:v})}c=m}let d=c+o;if(e.length<d)throw new Error(`Invalid snapshot: expected ${d} bytes, got ${e.length}`);return{memory:e.slice(c,c+o),stackPointer:i,runtimePtr:a,contextPtr:l,extensions:u}}static normalizeOptions(e){if(!e)return{wasm:void 0};if(e instanceof WebAssembly.Module)return{wasm:e};if(typeof e=="object"&&("wasm"in e||"wasi"in e||"memoryLimit"in e||"maxStackSize"in e||"interruptHandler"in e||"onUnhandledRejection"in e||"moduleLoader"in e||"intrinsics"in e||"extensions"in e||"timezoneOffset"in e)){let t=e;if(t.maxStackSize!==void 0&&(!Number.isInteger(t.maxStackSize)||t.maxStackSize<0||t.maxStackSize>ne))throw new RangeError(`maxStackSize must be an integer between 0 and ${ne}`);return t}return{wasm:e}}static applyLimits(e,t){t.memoryLimit!==void 0&&e.exports.qjs_set_memory_limit(t.memoryLimit),t.maxStackSize!==void 0&&e.exports.qjs_set_max_stack_size(t.maxStackSize),t.interruptHandler&&(e.interruptHandler=t.interruptHandler,e.exports.qjs_set_interrupt_handler(1)),t.onUnhandledRejection&&(e.unhandledRejectionHandler=t.onUnhandledRejection,e.exports.qjs_set_promise_rejection_handler(1)),t.moduleLoader&&(e.moduleLoadHandler=t.moduleLoader.load,e.moduleNormalizeHandler=t.moduleLoader.normalize??null,e.exports.qjs_set_module_loader(1));let r=t.timezoneOffset;if(typeof r=="function")e.timezoneOffsetHandler=s=>-r(s)*60;else if(typeof r=="number"){let s=-r*60;e.timezoneOffsetHandler=()=>s}else e.timezoneOffsetHandler=s=>-new Date(s*1e3).getTimezoneOffset()*60}static async resolveModule(e){if(e instanceof WebAssembly.Module)return e;if(e)return WebAssembly.compile(e);throw new TypeError("QuickJS: `wasm` option is required. Provide WASM bytes or a compiled `WebAssembly.Module`. The binary is shipped at `quickjs-wasi/quickjs.wasm` and can be loaded via your environment's preferred mechanism (e.g. `fetch()`, `node:fs/promises`, or a bundler import like Vite's `?url`).")}static async instantiate(e,t,r){let s=null,o=new Proxy({},{get(S,g){return s[g]}}),i=Re(()=>s),a=r?r(o):void 0,l={...i,...a},u=f((S,g,h,x,v)=>t.handleHostCall(S,g,h,x,v),"hostCall"),c=f(()=>t.interruptHandler&&t.interruptHandler()?1:0,"hostInterrupt"),d=f((S,g,h)=>{if(!t.unhandledRejectionHandler){t.exports.qjs_free_value(S),t.exports.qjs_free_value(g);return}let x=new b(t,S),v=new b(t,g);try{t.unhandledRejectionHandler(x,v,h!==0)}finally{x.dispose(),v.dispose()}},"hostPromiseRejection"),p=f(S=>{let g=t.newError(S instanceof Error?S:String(S));t.exports.qjs_throw(g.ptr),g.dispose()},"throwIntoContext"),_=f((S,g)=>{if(typeof S=="string")return S;let h=S!==null&&typeof S=="object"&&typeof S.then=="function"?"a Promise":`type ${typeof S}`;throw new TypeError(`moduleLoader.${g} must synchronously return a string (got ${h}). Async module loading is not supported. Pre-fetch module sources instead (see the "ES Modules" section of the quickjs-wasi README).`)},"assertSyncString"),m=f((S,g)=>{if(!t.moduleNormalizeHandler){let v=t.readCString(g);return t.writeString(v).ptr}let h=t.readCString(S),x=t.readCString(g);try{let v=_(t.moduleNormalizeHandler(h,x),"normalize");return t.writeString(v).ptr}catch(v){return p(v),0}},"hostModuleNormalize"),y=f((S,g)=>{if(!t.moduleLoadHandler)return 0;let h=t.readCString(S);try{let x=_(t.moduleLoadHandler(h),"load"),{ptr:v,len:O}=t.writeString(x);return new Uint32Array(t.exports.memory.buffer,g,1)[0]=O,v}catch(x){return p(x),0}},"hostModuleLoad"),E=f((S,g)=>{let h=Number(BigInt(S)<<32n|BigInt(g>>>0));return t.timezoneOffsetHandler?t.timezoneOffsetHandler(h):0},"hostGetTimezoneOffset"),k=await WebAssembly.instantiate(e,{env:{host_call:u,host_interrupt:c,host_promise_rejection:d,host_module_normalize:m,host_module_load:y,host_get_timezone_offset:E},wasi_snapshot_preview1:l});return s=k.exports.memory,{instance:k,wasiBuiltins:i,wasiUserOverrides:a,memoryProxy:o}}handleHostCall(e,t,r,s,o){let i=this.decoder.decode(new Uint8Array(this.exports.memory.buffer,e,t)),a=this.hostCallbacks.get(i);if(!a){let c=this.newError(`Host callback "${i}" is not registered: it was unregistered, its ephemeral function handle was disposed, or it was never re-registered after a snapshot restore.`);return this.exports.qjs_throw(c.ptr),c.dispose(),0}let l=new b(this,r,!1,!0),u=[];if(s>0&&o!==0){let c=new DataView(this.exports.memory.buffer);for(let d=0;d<s;d++){let p=c.getUint32(o+d*4,!0);u.push(new b(this,p,!1,!0))}}try{let c=a.call(l,...u);return this.exports.qjs_dup_value(c.ptr)}catch(c){let d=this.newError(c instanceof Error?c:String(c));return this.exports.qjs_throw(d.ptr),d.dispose(),0}}writeString(e){let t=ot(e),r=this.exports.wasm_malloc(t.length+1);if(r===0)throw new Error("wasm_malloc failed");let s=new Uint8Array(this.exports.memory.buffer);return s.set(t,r),s[r+t.length]=0,{ptr:r,len:t.length}}readCString(e){let t=new Uint8Array(this.exports.memory.buffer),r=e;for(;t[r]!==0;)r++;return this.decoder.decode(t.slice(e,r))}throwIfException(e){if(this.exports.qjs_is_exception(e.ptr)!==0){let t=this.getException();throw e.dispose(),this._ownedHandles.add(t),new B(t)}return e}evalCode(e,t="<eval>",r=0){this.assertNotDisposed();let s=this.writeString(e),o=this.writeString(t),i=this.exports.qjs_eval(s.ptr,s.len,o.ptr,r);return this.exports.wasm_free(s.ptr),this.exports.wasm_free(o.ptr),this.throwIfException(new b(this,i))}compile(e,t="<compile>",r=0,s=0){this.assertNotDisposed();let o=this.writeString(e),i=this.writeString(t),a=this.exports.wasm_malloc(4),l=this.exports.qjs_compile(o.ptr,o.len,i.ptr,r,s,a);if(this.exports.wasm_free(o.ptr),this.exports.wasm_free(i.ptr),l===0){this.exports.wasm_free(a);let d=this.getException();throw new Error(`Compilation error: ${d.toString()}`)}let u=new Uint32Array(this.exports.memory.buffer,a,1)[0];this.exports.wasm_free(a);let c=new Uint8Array(this.exports.memory.buffer,l,u).slice();return this.exports.wasm_free(l),c}evalBytecode(e){this.assertNotDisposed();let t=this.exports.wasm_malloc(e.byteLength);new Uint8Array(this.exports.memory.buffer,t,e.byteLength).set(e);let r=this.exports.qjs_eval_bytecode(t,e.byteLength);return this.exports.wasm_free(t),this.throwIfException(new b(this,r))}executePendingJobs(){this.assertNotDisposed();let e=0;for(;this.exports.qjs_is_job_pending();){if(this.exports.qjs_execute_pending_job()<0){let r=this.getException();throw new Error(`Job execution error: ${r.toString()}`)}e++}return e}runGC(){this.assertNotDisposed(),this.exports.qjs_run_gc()}get gcThreshold(){return this.assertNotDisposed(),this.exports.qjs_get_gc_threshold()}set gcThreshold(e){this.assertNotDisposed(),this.exports.qjs_set_gc_threshold(e)}getMemoryUsage(){this.assertNotDisposed();let e=this.exports.wasm_malloc(208);this.exports.qjs_compute_memory_usage(e);let t=new BigInt64Array(this.exports.memory.buffer,e,26),r={mallocSize:Number(t[0]),mallocLimit:Number(t[1]),memoryUsedSize:Number(t[2]),mallocCount:Number(t[3]),memoryUsedCount:Number(t[4]),atomCount:Number(t[5]),atomSize:Number(t[6]),strCount:Number(t[7]),strSize:Number(t[8]),objCount:Number(t[9]),objSize:Number(t[10]),propCount:Number(t[11]),propSize:Number(t[12]),shapeCount:Number(t[13]),shapeSize:Number(t[14]),jsFuncCount:Number(t[15]),jsFuncSize:Number(t[16]),jsFuncCodeSize:Number(t[17]),jsFuncPc2lineCount:Number(t[18]),jsFuncPc2lineSize:Number(t[19]),cFuncCount:Number(t[20]),arrayCount:Number(t[21]),fastArrayCount:Number(t[22]),fastArrayElements:Number(t[23]),binaryObjectCount:Number(t[24]),binaryObjectSize:Number(t[25])};return this.exports.wasm_free(e),r}getGlobal(){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_global())}newString(e){this.assertNotDisposed();let{ptr:t,len:r}=this.writeString(e),s=this.exports.qjs_new_string(t,r);return this.exports.wasm_free(t),new b(this,s)}newNumber(e){return this.assertNotDisposed(),new b(this,this.exports.qjs_new_number(e))}newBigInt(e){this.assertNotDisposed();let t=Number(e&0xffffffffn),r=Number(e>>32n&0xffffffffn);return new b(this,this.exports.qjs_new_big_int64(t,r))}newObject(){return this.assertNotDisposed(),new b(this,this.exports.qjs_new_object())}newArray(){return this.assertNotDisposed(),new b(this,this.exports.qjs_new_array())}newSymbolFor(e){this.assertNotDisposed();let{ptr:t,len:r}=this.writeString(e),s=new b(this,this.exports.qjs_new_symbol(t,r,1));return this.exports.wasm_free(t),s}newArrayBuffer(e){this.assertNotDisposed();let t=e instanceof ArrayBuffer?new Uint8Array(e):e,r=this.exports.wasm_malloc(t.length);if(r===0)throw new Error("wasm_malloc failed");new Uint8Array(this.exports.memory.buffer).set(t,r);let s=new b(this,this.exports.qjs_new_array_buffer(r,t.length));return this.exports.wasm_free(r),s}newUint8Array(e){this.assertNotDisposed();let t=this.exports.wasm_malloc(e.length);if(t===0)throw new Error("wasm_malloc failed");new Uint8Array(this.exports.memory.buffer).set(e,t);let r=new b(this,this.exports.qjs_new_uint8_array(t,e.length));return this.exports.wasm_free(t),r}getUndefined(){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_undefined())}getNull(){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_null())}getTrue(){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_true())}getFalse(){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_false())}newFunction(e,t){if(this.assertNotDisposed(),this.hostCallbacks.has(e))throw new Error(`Host callback with name "${e}" is already registered`);this.hostCallbacks.set(e,t);let{ptr:r,len:s}=this.writeString(e),o=this.exports.qjs_new_host_function(r,s,0);return this.exports.wasm_free(r),new b(this,o)}withScope(e){this.assertNotDisposed();let t=this._activeScope,r=new Set;this._activeScope=r;let s={escape:f(o=>(r.delete(o),t?.add(o),o),"escape")};try{return e(s)}finally{this._activeScope=t;for(let o of r)o.dispose()}}exportHandle(e){if(this.assertNotDisposed(),e.vm!==this)throw new Error("exportHandle: handle belongs to a different VM");if(e.disposed)throw new Error("exportHandle: handle is disposed");if(e._isBorrowed)throw new Error("exportHandle: cannot export a borrowed handle (host-callback this/argument); its box is freed when the callback returns. dup() it and export the duplicate.");return e.ptr}importHandle(e){if(this.assertNotDisposed(),!Number.isInteger(e)||e<=0||e>=this.exports.memory.buffer.byteLength)throw new Error(`importHandle: invalid token ${e}`);return new b(this,this.exports.qjs_dup_value(e))}newEphemeralFunction(e){this.assertNotDisposed();let t=`__ephemeral:${this.nextInternalId++}`;this.hostCallbacks.set(t,e);let{ptr:r,len:s}=this.writeString(t),o=this.exports.qjs_new_host_function(r,s,0);this.exports.wasm_free(r);let i=new b(this,o);return i._onDispose=()=>{this.hostCallbacks.delete(t)},i}unregisterHostCallback(e){return this.hostCallbacks.delete(e)}newInternalFunction(e,t){this.hostCallbacks.set(e,t);let{ptr:r,len:s}=this.writeString(e),o=this.exports.qjs_new_host_function(r,s,0);return this.exports.wasm_free(r),new b(this,o)}newPromise(){this.assertNotDisposed();let e=this.exports.wasm_malloc(4),t=this.exports.wasm_malloc(4),r=this.exports.qjs_new_promise(e,t),s=new DataView(this.exports.memory.buffer),o=s.getUint32(e,!0),i=s.getUint32(t,!0);this.exports.wasm_free(e),this.exports.wasm_free(t);let a=new b(this,r),l=new b(this,o),u=new b(this,i),c=this;c._ownedHandles.add(l),c._ownedHandles.add(u);let d=null;return{handle:a,get settled(){if(!d){let p;d=new Promise(y=>{p=y});let _=`__settle:${c.nextInternalId++}`,m=c.newInternalFunction(_,()=>(p(),c.hostCallbacks.delete(_),c.undefined));c.promiseThenRaw(a,m,m).dispose(),m.dispose()}return d},resolve(p){c.callFunctionRaw(l,c.undefined,p).dispose(),c._ownedHandles.delete(l),l.dispose()},reject(p){c.callFunctionRaw(u,c.undefined,p).dispose(),c._ownedHandles.delete(u),u.dispose()}}}resolvePromise(e){if(this.assertNotDisposed(),!this.exports.qjs_is_promise(e.ptr))return Promise.resolve({value:e.dup()});let t=this.exports.qjs_promise_state(e.ptr);return t===1?Promise.resolve({value:new b(this,this.exports.qjs_promise_result(e.ptr))}):t===2?Promise.resolve({error:new b(this,this.exports.qjs_promise_result(e.ptr))}):new Promise(r=>{let s=this.nextInternalId++,o=`__onFulfilled:${s}`,i=`__onRejected:${s}`,a=this.newInternalFunction(o,(...u)=>{let c=u[0]?.dup()??this.undefined;return this.hostCallbacks.delete(o),this.hostCallbacks.delete(i),r({value:c}),this.undefined}),l=this.newInternalFunction(i,(...u)=>{let c=u[0]?.dup()??this.undefined;return this.hostCallbacks.delete(o),this.hostCallbacks.delete(i),r({error:c}),this.undefined});this.promiseThenRaw(e,a,l).dispose(),a.dispose(),l.dispose()})}promiseThenRaw(e,t,r){return new b(this,this.exports.qjs_promise_then(e.ptr,t.ptr,r.ptr))}markPromiseHandled(e){this.assertNotDisposed(),this.exports.qjs_promise_mark_as_handled(e.ptr)}callFunction(e,t,...r){return this.throwIfException(this.callFunctionRaw(e,t,...r))}construct(e,...t){this.assertNotDisposed();let r=t.length,s=0;if(r>0){s=this.exports.wasm_malloc(r*4);let i=new DataView(this.exports.memory.buffer);for(let a=0;a<r;a++)i.setUint32(s+a*4,t[a].ptr,!0)}let o=this.exports.qjs_call_constructor(e.ptr,r,s);return s&&this.exports.wasm_free(s),this.throwIfException(new b(this,o))}callFunctionRaw(e,t,...r){this.assertNotDisposed();let s=r.length,o=0;if(s>0){o=this.exports.wasm_malloc(s*4);let a=new DataView(this.exports.memory.buffer);for(let l=0;l<s;l++)a.setUint32(o+l*4,r[l].ptr,!0)}let i=this.exports.qjs_call(e.ptr,t.ptr,s,o);return o&&this.exports.wasm_free(o),new b(this,i)}setProp(e,t,r){if(this.assertNotDisposed(),typeof t=="string"){let{ptr:s}=this.writeString(t);this.exports.qjs_set_prop_string(e.ptr,s,r.ptr),this.exports.wasm_free(s)}else this.exports.qjs_set_prop_value(e.ptr,t.ptr,r.ptr)}defineProp(e,t,r,s){this.assertNotDisposed();let o=0;if(s?.configurable&&(o|=1),s?.writable&&(o|=2),s?.enumerable&&(o|=4),typeof t=="string"){let{ptr:i}=this.writeString(t);this.exports.qjs_define_prop_string(e.ptr,i,r.ptr,o),this.exports.wasm_free(i)}else this.exports.qjs_define_prop_value(e.ptr,t.ptr,r.ptr,o)}getProp(e,t){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_prop_value(e.ptr,t.ptr))}getException(){return this.assertNotDisposed(),new b(this,this.exports.qjs_get_exception())}newError(e){this.assertNotDisposed();let t=this.exports.qjs_new_error(),r=new b(this,t);if(typeof e=="string"){let s=this.newString(e);r.setProp("message",s),s.dispose()}else{let s=this.newString(e.message);if(r.setProp("message",s),s.dispose(),e.name){let o=this.newString(e.name);r.setProp("name",o),o.dispose()}if(e.stack){let o=this.newString(e.stack);r.setProp("stack",o),o.dispose()}}return r}typeof(e){this.assertNotDisposed();let t=this.exports;return t.qjs_is_undefined(e.ptr)?"undefined":t.qjs_is_null(e.ptr)?"object":t.qjs_is_bool(e.ptr)?"boolean":t.qjs_is_number(e.ptr)?"number":t.qjs_is_big_int(e.ptr)?"bigint":t.qjs_is_string(e.ptr)?"string":t.qjs_is_symbol(e.ptr)?"symbol":t.qjs_is_function(e.ptr)?"function":t.qjs_is_object(e.ptr)?"object":"unknown"}dump(e){return this.assertNotDisposed(),this._dump(e,new Map)}_dump(e,t){let r=this.exports;if(!r.qjs_is_undefined(e.ptr)){if(r.qjs_is_null(e.ptr))return null;if(r.qjs_is_bool(e.ptr))return r.qjs_get_bool(e.ptr)!==0;if(r.qjs_is_number(e.ptr))return r.qjs_get_float64(e.ptr);if(r.qjs_is_string(e.ptr))return e.toString();if(r.qjs_is_big_int(e.ptr))return e.toBigInt();if(r.qjs_is_symbol(e.ptr)){let s=r.wasm_malloc(4),o=r.qjs_get_symbol_description(e.ptr,s),a=new DataView(r.memory.buffer).getUint32(s,!0);if(r.wasm_free(s),o===1){let l=new b(this,a),u=l.toString();return l.dispose(),Symbol.for(u)}else if(o===2){new b(this,a).dispose();return}return}if(r.qjs_is_array_buffer(e.ptr))return e.toArrayBuffer();if(r.qjs_is_exception(e.ptr)){let s=this.getException(),o=s.toString();return s.dispose(),new Error(o)}if(!r.qjs_is_function(e.ptr)){if(r.qjs_is_object(e.ptr)){let s=r.qjs_get_value_ptr(e.ptr);if(s){let o=t.get(s);if(o!==void 0)return o}}if(r.qjs_is_object(e.ptr)){let s=r.wasm_malloc(4),o=r.wasm_malloc(4),i=r.wasm_malloc(4),a=r.qjs_get_typed_array_buffer(e.ptr,s,o,i),l=new b(this,a);if(r.qjs_is_exception(l.ptr)===0){let u=new DataView(r.memory.buffer),c=u.getUint32(s,!0),d=u.getUint32(o,!0),p=u.getUint32(i,!0);r.wasm_free(s),r.wasm_free(o),r.wasm_free(i);let _=r.wasm_malloc(4),m=r.qjs_get_array_buffer(l.ptr,_);if(r.wasm_free(_),l.dispose(),m!==0){let y=new Uint8Array(r.memory.buffer,m+c,d).slice();switch(p){case 1:return y;case 2:return new Uint16Array(y.buffer);case 4:return new Uint32Array(y.buffer);case 8:return new Float64Array(y.buffer);default:return y}}}else l.dispose(),r.wasm_free(s),r.wasm_free(o),r.wasm_free(i)}if(r.qjs_is_array(e.ptr)){let s=e.getProp("length"),o=r.qjs_get_float64(s.ptr);s.dispose();let i=[],a=r.qjs_get_value_ptr(e.ptr);a&&t.set(a,i);for(let l=0;l<o;l++){let u=r.qjs_get_prop_uint32(e.ptr,l),c=new b(this,u);i.push(this._dump(c,t)),c.dispose()}return i}if(r.qjs_is_error(e.ptr)){let s=e.getProp("name"),o=e.getProp("message"),i=e.getProp("stack"),a=s.isUndefined?"Error":s.toString(),l=o.isUndefined?"":o.toString(),u=i.isUndefined?void 0:i.toString();s.dispose(),o.dispose(),i.dispose();let c=new Error(l);return c.name=a,u!==void 0&&(c.stack=u),c}if(r.qjs_is_object(e.ptr)){let s=r.qjs_get_own_property_names(e.ptr),o=new b(this,s);if(r.qjs_is_exception(o.ptr)!==0)return o.dispose(),{};let i=o.getProp("length"),a=r.qjs_get_float64(i.ptr);i.dispose();let l={},u=r.qjs_get_value_ptr(e.ptr);u&&t.set(u,l);for(let c=0;c<a;c++){let d=r.qjs_get_prop_uint32(o.ptr,c),p=new b(this,d),_=p.toString();p.dispose();let m=e.getProp(_);l[_]=this._dump(m,t),m.dispose()}return o.dispose(),l}}}}hostToHandle(e){if(this.assertNotDisposed(),e===void 0)return this.undefined;if(e===null)return this.null;if(e===!0)return this.true;if(e===!1)return this.false;if(typeof e=="number")return this.newNumber(e);if(typeof e=="string")return this.newString(e);if(typeof e=="bigint")return this.newBigInt(e);if(typeof e=="symbol"){let t=Symbol.keyFor(e);if(t!==void 0)return this.newSymbolFor(t);throw new Error("Cannot convert local symbol to QuickJS handle. Use Symbol.for() for cross-boundary symbols.")}if(e instanceof Promise){let t=this.newPromise();return e.then(r=>{t.resolve(this.hostToHandle(r)),this.executePendingJobs()},r=>{t.reject(this.hostToHandle(r)),this.executePendingJobs()}),t.handle}if(e instanceof Error)return this.newError(e);if(e instanceof ArrayBuffer)return this.newArrayBuffer(e);if(e instanceof Uint8Array)return this.newUint8Array(e);if(ArrayBuffer.isView(e))return this.newArrayBuffer(new Uint8Array(e.buffer,e.byteOffset,e.byteLength));if(Array.isArray(e)){let t=this.newArray();for(let r=0;r<e.length;r++){let s=this.hostToHandle(e[r]);this.exports.qjs_set_prop_uint32(t.ptr,r,s.ptr),s.dispose()}return t}if(typeof e=="object"&&e!==null){let t=this.newObject();for(let[r,s]of Object.entries(e)){let o=this.hostToHandle(s);t.setProp(r,o),o.dispose()}return t}return this.undefined}snapshot(){return this.assertNotDisposed(),{memory:new Uint8Array(this.exports.memory.buffer).slice(),stackPointer:this.exports.__stack_pointer.value,runtimePtr:this.exports.qjs_get_runtime_ptr(),contextPtr:this.exports.qjs_get_context_ptr(),extensions:this.loadedExtensions.map(e=>({name:e.name,memoryBase:e.memoryBase,tableBase:e.tableBase,initFn:e.initFn}))}}registerHostCallback(e,t){this.hostCallbacks.set(e,t)}dispose(){this.disposed||(this.disposed=!0,this._global=null,this._undefined=null,this._null=null,this._true=null,this._false=null,this._ownedHandles.clear(),this.hostCallbacks.clear(),this._activeScope=null,this.exports=null,this.instance=null,this.module=null)}[Symbol.dispose](){this.dispose()}assertNotDisposed(){if(this.disposed)throw new Error("QuickJS instance has been disposed")}_getExports(){return this.exports}_getMemory(){return this.exports.memory}_writeString(e){return this.writeString(e)}_readCString(e){return this.readCString(e)}};f(P,"QuickJS");var oe=P;function K(n){return n.includes("\0")||Me.test(n)}f(K,"stringKeyNeedsValuePath");var st=new TextDecoder,nt=new TextEncoder,Me=new RegExp("(?:[\\uD800-\\uDBFF](?![\\uDC00-\\uDFFF]))|(?:(?<![\\uD800-\\uDBFF])[\\uDC00-\\uDFFF])");function ot(n){if(!Me.test(n))return nt.encode(n);let e=[];for(let t=0;t<n.length;t++){let r=n.charCodeAt(t);if(r<128)e.push(r);else if(r<2048)e.push(192|r>>6,128|r&63);else if(r>=55296&&r<=56319&&t+1<n.length){let s=n.charCodeAt(t+1);if(s>=56320&&s<=57343){let o=65536+(r-55296<<10)+(s-56320);e.push(240|o>>18,128|o>>12&63,128|o>>6&63,128|o&63),t++;continue}e.push(224|r>>12,128|r>>6&63,128|r&63)}else e.push(224|r>>12,128|r>>6&63,128|r&63)}return new Uint8Array(e)}f(ot,"encodeWtf8");function it(n){let e=!1;for(let s=0;s<n.length-1;s++)if(n[s]===237&&n[s+1]>=160&&n[s+1]<=191){e=!0;break}if(!e)return st.decode(n);let t="",r=0;for(;r<n.length;){let s=n[r];if(s<128)t+=String.fromCharCode(s),r+=1;else if(s<224)t+=String.fromCharCode((s&31)<<6|n[r+1]&63),r+=2;else if(s<240)t+=String.fromCharCode((s&15)<<12|(n[r+1]&63)<<6|n[r+2]&63),r+=3;else{let o=(s&7)<<18|(n[r+1]&63)<<12|(n[r+2]&63)<<6|n[r+3]&63;t+=String.fromCodePoint(o),r+=4}}return t}f(it,"decodeWtf8");var J,W,V,ve=class ve extends Error{constructor(t){var e=(...$t)=>(super(...$t),H(this,"handle"),M(this,J),M(this,W),M(this,V),this);let r={stack:[],error:void 0,hasError:!1};try{e(),this.handle=t,delete this.stack;let s=F(r,t.getProp("message"),!1);q(this,J,t.getProp("name").consume(o=>o.isUndefined?"Error":o.toString())),q(this,W,s.isUndefined?t.toString():s.toString()),q(this,V,t.getProp("stack").consume(o=>o.isUndefined?void 0:o.toString()))}catch(s){r.error=s,r.hasError=!0}finally{$(r)}}get name(){return N(this,J)}set name(t){q(this,J,t)}get message(){return N(this,W)}set message(t){q(this,W,t)}get stack(){return N(this,V)}set stack(t){q(this,V,t)}dispose(){this.handle.dispose()}[Symbol.dispose](){this.handle.dispose()}};J=new WeakMap,W=new WeakMap,V=new WeakMap,f(ve,"JSException");var B=ve,A=class A{vm;ptr;disposed_=!1;singleton;borrowed;_onDispose;constructor(e,t,r=!1,s=!1){this.vm=e,this.ptr=t,this.singleton=r,this.borrowed=s,!r&&!s&&e._activeScope?.add(this)}get _isBorrowed(){return this.borrowed}get disposed(){return this.disposed_}get isUndefined(){return this.vm._getExports().qjs_is_undefined(this.ptr)!==0}get isNull(){return this.vm._getExports().qjs_is_null(this.ptr)!==0}get isBool(){return this.vm._getExports().qjs_is_bool(this.ptr)!==0}get isNumber(){return this.vm._getExports().qjs_is_number(this.ptr)!==0}get isString(){return this.vm._getExports().qjs_is_string(this.ptr)!==0}get isSymbol(){return this.vm._getExports().qjs_is_symbol(this.ptr)!==0}get isBigInt(){return this.vm._getExports().qjs_is_big_int(this.ptr)!==0}get isObject(){return this.vm._getExports().qjs_is_object(this.ptr)!==0}get isArray(){return this.vm._getExports().qjs_is_array(this.ptr)!==0}get isFunction(){return this.vm._getExports().qjs_is_function(this.ptr)!==0}get isError(){return this.vm._getExports().qjs_is_error(this.ptr)!==0}get isPromise(){return this.vm._getExports().qjs_is_promise(this.ptr)!==0}get isArrayBuffer(){return this.vm._getExports().qjs_is_array_buffer(this.ptr)!==0}get isProxy(){return this.vm._getExports().qjs_is_proxy(this.ptr)!==0}get isMap(){return this.vm._getExports().qjs_is_map(this.ptr)!==0}get isSet(){return this.vm._getExports().qjs_is_set(this.ptr)!==0}get isDate(){return this.vm._getExports().qjs_is_date(this.ptr)!==0}get isRegExp(){return this.vm._getExports().qjs_is_regexp(this.ptr)!==0}get isWeakRef(){return this.vm._getExports().qjs_is_weak_ref(this.ptr)!==0}get isWeakMap(){return this.vm._getExports().qjs_is_weak_map(this.ptr)!==0}get isWeakSet(){return this.vm._getExports().qjs_is_weak_set(this.ptr)!==0}get isDataView(){return this.vm._getExports().qjs_is_data_view(this.ptr)!==0}get identity(){return this.vm._getExports().qjs_get_value_ptr(this.ptr)}toBoolean(){return this.vm._getExports().qjs_get_bool(this.ptr)!==0}get classId(){return this.vm._getExports().qjs_get_class_id(this.ptr)}get className(){let e=new A(this.vm,this.vm._getExports().qjs_get_class_name(this.ptr));if(this.vm._getExports().qjs_is_exception(e.ptr)!==0)throw e.dispose(),new B(this.vm.getException());try{return e.isUndefined?void 0:e.toString()}finally{e.dispose()}}get promiseState(){return this.vm._getExports().qjs_promise_state(this.ptr)}get typeof(){return this.vm.typeof(this)}get length(){let e=this.getProp("length"),t=e.toNumber();return e.dispose(),t}get constructorName(){let e=this.getProp("constructor");if(e.isUndefined||e.isNull){e.dispose();return}let t=e.getProp("name");if(e.dispose(),t.isUndefined||t.isNull){t.dispose();return}let r=t.toString();return t.dispose(),r}keys(){let e=this.vm._getExports(),t=e.qjs_get_own_property_names(this.ptr),r=new A(this.vm,t);if(e.qjs_is_exception(r.ptr)!==0)return r.dispose(),[];let s=r.getProp("length"),o=e.qjs_get_float64(s.ptr);s.dispose();let i=[];for(let a=0;a<o;a++){let l=e.qjs_get_prop_uint32(r.ptr,a),u=new A(this.vm,l);i.push(u.toString()),u.dispose()}return r.dispose(),i}getOwnPropertyNames(){let e=this.vm._getExports(),t=e.qjs_get_own_property_names_all(this.ptr),r=new A(this.vm,t);if(e.qjs_is_exception(r.ptr)!==0)return r.dispose(),[];let s=r.getProp("length"),o=e.qjs_get_float64(s.ptr);s.dispose();let i=[];for(let a=0;a<o;a++){let l=e.qjs_get_prop_uint32(r.ptr,a),u=new A(this.vm,l);i.push(u.toString()),u.dispose()}return r.dispose(),i}getOwnPropertyKeys(){let e=this.vm._getExports(),t=e.qjs_get_own_property_keys(this.ptr),r=new A(this.vm,t);if(e.qjs_is_exception(r.ptr)!==0)return r.dispose(),[];let s=r.getProp("length"),o=e.qjs_get_float64(s.ptr);s.dispose();let i=[];for(let a=0;a<o;a++){let l=e.qjs_get_prop_uint32(r.ptr,a),u=new A(this.vm,l);u.isSymbol?i.push(u):(i.push(u.toString()),u.dispose())}return r.dispose(),i}getOwnPropertyDescriptor(e){let t={stack:[],error:void 0,hasError:!1};try{let r=this.vm._getExports(),s,o;typeof e=="string"?(s=this.vm.newString(e),o=s.ptr):o=e.ptr;let i=r.qjs_get_own_property_descriptor(this.ptr,o);if(s?.dispose(),i===0)return;let a=F(t,new A(this.vm,i),!1);if(r.qjs_is_exception(a.ptr)!==0)throw new B(this.vm.getException());let l=a.getProp("enumerable").consume(c=>r.qjs_get_bool(c.ptr)!==0),u=a.getProp("configurable").consume(c=>r.qjs_get_bool(c.ptr)!==0);return a.hasOwnProperty("value")?{value:a.getProp("value"),writable:a.getProp("writable").consume(c=>r.qjs_get_bool(c.ptr)!==0),enumerable:l,configurable:u}:{get:a.getProp("get"),set:a.getProp("set"),enumerable:l,configurable:u}}catch(r){t.error=r,t.hasError=!0}finally{$(t)}}hasOwnProperty(e){if(K(e)){let s={stack:[],error:void 0,hasError:!1};try{let o=F(s,this.vm.newString(e),!1);return this.vm._getExports().qjs_has_own_property_value(this.ptr,o.ptr)===1}catch(o){s.error=o,s.hasError=!0}finally{$(s)}}let{ptr:t}=this.vm._writeString(e),r=this.vm._getExports().qjs_has_own_property(this.ptr,t);return this.vm._getExports().wasm_free(t),r===1}propertyIsEnumerable(e){if(K(e)){let s={stack:[],error:void 0,hasError:!1};try{let o=F(s,this.vm.newString(e),!1);return this.vm._getExports().qjs_property_is_enumerable_value(this.ptr,o.ptr)===1}catch(o){s.error=o,s.hasError=!0}finally{$(s)}}let{ptr:t}=this.vm._writeString(e),r=this.vm._getExports().qjs_property_is_enumerable(this.ptr,t);return this.vm._getExports().wasm_free(t),r===1}getPrototypeOf(){let e=this.vm._getExports().qjs_get_prototype_of(this.ptr);return new A(this.vm,e)}getProxyTarget(){let e=this.vm._getExports().qjs_get_proxy_target(this.ptr),t=new A(this.vm,e);if(this.vm._getExports().qjs_is_exception(t.ptr)!==0)throw t.dispose(),new B(this.vm.getException());return t}getProxyHandler(){let e=this.vm._getExports().qjs_get_proxy_handler(this.ptr),t=new A(this.vm,e);if(this.vm._getExports().qjs_is_exception(t.ptr)!==0)throw t.dispose(),new B(this.vm.getException());return t}getProp(e){if(K(e)){let s={stack:[],error:void 0,hasError:!1};try{let o=F(s,this.vm.newString(e),!1);return this.vm.getProp(this,o)}catch(o){s.error=o,s.hasError=!0}finally{$(s)}}let{ptr:t}=this.vm._writeString(e),r=this.vm._getExports().qjs_get_prop_string(this.ptr,t);return this.vm._getExports().wasm_free(t),new A(this.vm,r)}setProp(e,t){if(K(e)){let s={stack:[],error:void 0,hasError:!1};try{let o=F(s,this.vm.newString(e),!1);this.vm.setProp(this,o,t);return}catch(o){s.error=o,s.hasError=!0}finally{$(s)}}let{ptr:r}=this.vm._writeString(e);this.vm._getExports().qjs_set_prop_string(this.ptr,r,t.ptr),this.vm._getExports().wasm_free(r)}defineProp(e,t,r){let s=0;if(r?.configurable&&(s|=1),r?.writable&&(s|=2),r?.enumerable&&(s|=4),typeof e=="string"){if(K(e)){let i={stack:[],error:void 0,hasError:!1};try{let a=F(i,this.vm.newString(e),!1);this.vm._getExports().qjs_define_prop_value(this.ptr,a.ptr,t.ptr,s);return}catch(a){i.error=a,i.hasError=!0}finally{$(i)}}let{ptr:o}=this.vm._writeString(e);this.vm._getExports().qjs_define_prop_string(this.ptr,o,t.ptr,s),this.vm._getExports().wasm_free(o)}else this.vm._getExports().qjs_define_prop_value(this.ptr,e.ptr,t.ptr,s)}toNumber(){return this.vm._getExports().qjs_get_float64(this.ptr)}toBigInt(){let e=this.vm._getExports(),t=e.wasm_malloc(4),r=e.wasm_malloc(4);if(e.qjs_get_big_int64(this.ptr,t,r)!==0)throw e.wasm_free(t),e.wasm_free(r),new Error("Failed to convert value to BigInt");let o=new DataView(e.memory.buffer),i=o.getUint32(t,!0),a=o.getInt32(r,!0);return e.wasm_free(t),e.wasm_free(r),BigInt(a)<<32n|BigInt(i)}toArrayBuffer(){let e=this.vm._getExports(),t=e.wasm_malloc(4);if(e.qjs_is_array_buffer(this.ptr)){let _=e.qjs_get_array_buffer(this.ptr,t);if(_===0)throw e.wasm_free(t),new Error("Failed to get ArrayBuffer data");let y=new DataView(e.memory.buffer).getUint32(t,!0);return e.wasm_free(t),new Uint8Array(e.memory.buffer,_,y).slice().buffer}e.wasm_free(t);let r=e.wasm_malloc(4),s=e.wasm_malloc(4),o=e.wasm_malloc(4),i=e.qjs_get_typed_array_buffer(this.ptr,r,s,o),a=new A(this.vm,i);if(this.vm._getExports().qjs_is_exception(a.ptr)!==0)throw a.dispose(),e.wasm_free(r),e.wasm_free(s),e.wasm_free(o),new Error("Value is not an ArrayBuffer or typed array");let l=new DataView(e.memory.buffer),u=l.getUint32(r,!0),c=l.getUint32(s,!0);e.wasm_free(r),e.wasm_free(s),e.wasm_free(o);let d=e.wasm_malloc(4),p=e.qjs_get_array_buffer(a.ptr,d);if(e.wasm_free(d),a.dispose(),p===0)throw new Error("Failed to get ArrayBuffer data from typed array");return new Uint8Array(e.memory.buffer,p+u,c).slice().buffer}toUint8Array(){return new Uint8Array(this.toArrayBuffer())}toString(){let e=this.vm._getExports(),t=e.wasm_malloc(4);if(t===0)throw new Error("wasm_malloc failed");try{let r=e.qjs_get_string_len(this.ptr,t);if(r===0)return"<null>";let s=new DataView(e.memory.buffer).getUint32(t,!0),o=new Uint8Array(e.memory.buffer,r,s),i=it(o);return e.qjs_free_cstring(r),i}finally{e.wasm_free(t)}}consume(e){try{return e(this)}finally{this.dispose()}}dup(){return new A(this.vm,this.vm._getExports().qjs_dup_value(this.ptr))}dispose(){if(!(this.singleton||this.borrowed)&&!this.disposed_){this.disposed_=!0,this._onDispose?.(),this._onDispose=void 0;let e=this.vm._getExports();e&&e.qjs_free_value(this.ptr)}}[Symbol.dispose](){this.dispose()}};f(A,"JSValueHandle");var b=A;var ie='image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }',Ee=`(function (bridge, toolsJson, globalsJson, storeJson) {
	"use strict";

	// Freeze every object reachable from the built-in globals, plus the intrinsics that are only
	// reachable from instances (iterator and generator prototypes, %TypedArray%).
	//
	// Freezing alone breaks ordinary code through the "override mistake": a data property that is
	// read-only on a prototype cannot be assigned on an instance either, so
	// this.name = "MyError" in an Error subclass would throw. Commonly overridden properties
	// become accessors whose setter defines an own property on the instance instead.
	(function lockdown() {
		const OVERRIDABLE = new Set(["constructor", "name", "message", "toString", "toLocaleString", "valueOf", "toJSON"]);
		const seen = new Set([globalThis]);
		const queue = [];
		const add = (value) => {
			if ((typeof value === "object" && value !== null) || typeof value === "function") {
				if (!seen.has(value)) {
					seen.add(value);
					queue.push(value);
				}
			}
		};

		// Accessors from an object literal have no own prototype object, unlike function expressions,
		// whose prototype.constructor would be converted again without end.
		function allowOverride(object, key, value, enumerable) {
			const { get, set } = Object.getOwnPropertyDescriptor(
				{
					get accessor() {
						return value;
					},
					set accessor(next) {
						if (this === object) {
							throw new TypeError("Cannot assign to read only property '" + String(key) + "' of a built-in");
						}
						if ((typeof this !== "object" || this === null) && typeof this !== "function") return;
						Object.defineProperty(this, key, { value: next, writable: true, enumerable: true, configurable: true });
					},
				},
				"accessor",
			);
			Object.defineProperty(object, key, { get, set, enumerable, configurable: false });
			add(get);
			add(set);
		}

		for (const key of Reflect.ownKeys(globalThis)) {
			const descriptor = Object.getOwnPropertyDescriptor(globalThis, key);
			add(descriptor.value);
			add(descriptor.get);
			add(descriptor.set);
			if ("value" in descriptor && descriptor.configurable) {
				Object.defineProperty(globalThis, key, { writable: false, configurable: false });
			}
		}
		add(Object.getPrototypeOf(function* () {}));
		add(Object.getPrototypeOf(async function () {}));
		add(Object.getPrototypeOf(async function* () {}));
		add(Object.getPrototypeOf(Int8Array));
		add(Object.getPrototypeOf([][Symbol.iterator]()));
		add(Object.getPrototypeOf(new Map()[Symbol.iterator]()));
		add(Object.getPrototypeOf(new Set()[Symbol.iterator]()));
		add(Object.getPrototypeOf(""[Symbol.iterator]()));
		add(Object.getPrototypeOf(/a/[Symbol.matchAll]("")));
		if (typeof Iterator === "function") {
			if (typeof Iterator.prototype.map === "function") add(Object.getPrototypeOf([].values().map((x) => x)));
			if (typeof Iterator.from === "function") add(Object.getPrototypeOf(Iterator.from({ next() {} })));
		}

		while (queue.length > 0) {
			const object = queue.pop();
			add(Object.getPrototypeOf(object));
			const descriptors = Object.getOwnPropertyDescriptors(object);
			for (const key of Reflect.ownKeys(descriptors)) {
				const descriptor = descriptors[key];
				if ("value" in descriptor) {
					add(descriptor.value);
					if (
						descriptor.writable &&
						descriptor.configurable &&
						(object === Object.prototype || OVERRIDABLE.has(key))
					) {
						allowOverride(object, key, descriptor.value, descriptor.enumerable);
					}
				} else {
					add(descriptor.get);
					add(descriptor.set);
				}
			}
			Object.freeze(object);
		}
	})();
	const stringify = JSON.stringify;
	const parse = JSON.parse;
	const promiseThen = Promise.prototype.then;
	const ErrorCtor = Error;
	const TypeErrorCtor = TypeError;
	const RangeErrorCtor = RangeError;
	const pending = new Map();
	let nextId = 1;
	let finished = false;
	// Thrown by exit() to unwind the script after it already reported success.
	const EXIT = Object.freeze({});

	function done(ok, payload, writes) {
		if (finished) return;
		finished = true;
		bridge("done", ok, payload, writes);
	}

	function serialize(value) {
		return value === undefined ? undefined : stringify(value);
	}

	// QuickJS stacks list frames only. Prefix "Name: message" like V8 so the
	// text reads the same as a Node error, and drop this prelude's frames.
	function errorText(error) {
		const head = error.message ? error.name + ": " + error.message : String(error.name);
		const frames =
			typeof error.stack === "string"
				? error.stack.split("\\n").filter((line) => line.trim() && !line.includes("codemode-prelude.js"))
				: [];
		return [head, ...frames].join("\\n");
	}

	function format(value) {
		if (typeof value === "string") return value;
		if (value instanceof ErrorCtor) return errorText(value);
		try {
			const json = stringify(value);
			return json === undefined ? String(value) : json;
		} catch {
			return String(value);
		}
	}

	// The host requires string fields. A script can set an error's name or message to anything, so
	// they are coerced, and a value whose coercion throws gets a placeholder.
	function describeError(error) {
		try {
			if (error instanceof ErrorCtor) {
				return stringify({ name: String(error.name), message: String(error.message), stack: errorText(error) });
			}
			return stringify({ message: String(format(error)) });
		} catch {
			return stringify({ message: "The script threw a value that cannot be described" });
		}
	}

	function caller(kind, name, spread) {
		return (...args) =>
			new Promise((resolve, reject) => {
				let json;
				try {
					json = serialize(spread ? args : args[0]);
				} catch (error) {
					reject(error);
					return;
				}
				const id = nextId++;
				pending.set(id, { resolve, reject });
				bridge(kind, id, name, json);
			});
	}

	const tools = Object.create(null);
	const allTools = [];
	for (const { name, jsName, description } of parse(toolsJson)) {
		const fn = caller("call", name);
		// The first tool wins when two names normalize to the same identifier.
		if (!(jsName in tools)) {
			tools[jsName] = fn;
			allTools.push(Object.freeze({ name: jsName, description }));
		}
		if (!(name in tools)) tools[name] = fn;
	}
	Object.freeze(tools);
	Object.freeze(allTools);

	// Reading a member that does not exist throws an error that names the close matches, instead of
	// a later "not a function". \`in\` checks still work.
	const comparable = (name) => name.toLowerCase().replace(/[^a-z0-9]/g, "");
	function guard(target, label, names, hint) {
		return new Proxy(target, {
			get(object, property, receiver) {
				if (typeof property !== "string" || property in object || property in Object.prototype || property === "then" || property === "toJSON") {
					return Reflect.get(object, property, receiver);
				}
				const wanted = comparable(property);
				const exact = names.filter((name) => comparable(name) === wanted);
				const close = exact.length > 0 ? exact : names.filter((name) => wanted && (comparable(name).includes(wanted) || wanted.includes(comparable(name))));
				let message = label + "." + property + " does not exist.";
				if (close.length > 0) message += " Did you mean " + close.slice(0, 5).map((name) => label + "." + name).join(", ") + "?";
				else if (names.length <= 20) message += " Available: " + names.join(", ") + ".";
				if (hint) message += " " + hint;
				message += ' Check for a member with "' + property + '" in ' + label + ".";
				throw new TypeErrorCtor(message);
			},
		});
	}
	const toolsProxy = guard(
		tools,
		"tools",
		allTools.map((tool) => tool.name),
		"ALL_TOOLS lists every tool; searchTools(query) finds tools by topic.",
	);

	const namespaces = new Map();
	for (const { name, spread } of parse(globalsJson)) {
		const fn = caller("global", name, spread);
		const dot = name.indexOf(".");
		if (dot === -1) {
			Object.defineProperty(globalThis, name, { value: fn, enumerable: true });
			continue;
		}
		const namespace = name.slice(0, dot);
		if (!namespaces.has(namespace)) namespaces.set(namespace, Object.create(null));
		namespaces.get(namespace)[name.slice(dot + 1)] = fn;
	}
	for (const [namespace, members] of namespaces) {
		Object.freeze(members);
		const value = guard(members, namespace, Object.keys(members));
		Object.defineProperty(globalThis, namespace, { value, enumerable: true });
	}

	// key -> JSON text. Sizes count key and JSON characters.
	const stored = new Map(Object.entries(parse(storeJson)));
	const writes = new Map();
	let storedChars = 0;
	for (const [key, json] of stored) storedChars += key.length + json.length;

	const STORE_HINT =
		"store() is for small state such as IDs or summaries. Show images with image(), keep large data in variables, or write it to a file with a tool.";

	function checkKey(name, key) {
		if (typeof key !== "string") throw new TypeError(name + "() key must be a string");
	}

	function store(key, value) {
		checkKey("store", key);
		const previous = stored.has(key) ? key.length + stored.get(key).length : 0;
		if (value === undefined) {
			stored.delete(key);
			storedChars -= previous;
			writes.set(key, undefined);
			return;
		}
		let json;
		try {
			json = stringify(value);
		} catch (error) {
			throw new TypeError("store(" + stringify(key) + ") value is not JSON-serializable: " + format(error));
		}
		if (json === undefined) {
			throw new TypeError("store(" + stringify(key) + ") value is not JSON-serializable");
		}
		if (json.length > 262144) {
			throw new RangeError(
				"store(" + stringify(key) + ") value has " + json.length + " characters of JSON, more than the limit of 262144. " +
					STORE_HINT,
			);
		}
		const next = storedChars - previous + key.length + json.length;
		if (next > 1048576) {
			throw new RangeError(
				"store is full: stored values would exceed 1048576 characters of JSON. Delete keys with store(key, undefined). " +
					STORE_HINT,
			);
		}
		stored.set(key, json);
		storedChars = next;
		writes.set(key, json);
	}

	function load(key) {
		checkKey("load", key);
		const json = stored.get(key);
		return json === undefined ? undefined : parse(json);
	}

	function serializeWrites() {
		const entries = [];
		for (const [key, json] of writes) entries.push(json === undefined ? [key] : [key, json]);
		return stringify(entries);
	}

	Object.defineProperty(globalThis, "store", { value: store, enumerable: true });
	Object.defineProperty(globalThis, "load", { value: load, enumerable: true });

	let outputChars = 0;
	let outputItems = 0;

	// Past the output limits the script fails: done() reports the error, so catching it does not
	// resume output, and the host ends the script.
	function output(kind, data, mimeType) {
		if (finished) return;
		outputChars += data.length;
		outputItems++;
		if (outputChars > 16777216 || outputItems > 100000) {
			const error = new RangeErrorCtor(
				"script output exceeded the limit of 16777216 characters or 100000 text(), image(), and console calls. " +
					"Print a summary instead, or write large data to a file with a tool.",
			);
			done(false, describeError(error));
			throw error;
		}
		bridge("output", kind, data, mimeType);
	}

	// Primitives become their string form, everything else JSON.
	function outputText(value) {
		if (value === undefined || value === null || typeof value !== "object" && typeof value !== "function") {
			return String(value);
		}
		const json = stringify(value);
		return json === undefined ? String(value) : json;
	}

	function text(value) {
		let rendered;
		try {
			rendered = outputText(value);
		} catch (error) {
			throw new TypeErrorCtor(error instanceof ErrorCtor ? error.message : String(error));
		}
		output("text", rendered);
	}

	function imageUrl(value) {
		if (typeof value === "string") return value;
		if (typeof value !== "object" || value === null || Array.isArray(value)) {
			throw new TypeErrorCtor(${JSON.stringify(ie)});
		}
		if (value.image_url !== undefined) {
			if (typeof value.image_url !== "string") throw new TypeErrorCtor(${JSON.stringify(ie)});
			return value.image_url;
		}
		if (typeof value.type !== "string") throw new TypeErrorCtor(${JSON.stringify(ie)});
		if (value.type !== "image") {
			throw new TypeErrorCtor('image only accepts image blocks, got "' + value.type + '"');
		}
		if (typeof value.data !== "string" || value.data === "") throw new TypeErrorCtor("image expected image block data");
		if (value.data.toLowerCase().startsWith("data:")) return value.data;
		return "data:;base64," + value.data;
	}

	// Base64 of the signatures of the formats providers accept inline (PNG, JPEG except
	// JPEG-LS, GIF, "RIFF....WEBP"). Signatures start at byte 0, so their encodings are prefixes.
	const IMAGE_SIGNATURES = [
		["image/png", /^iVBORw0KGg/],
		["image/jpeg", /^[/]9j[/](?!9)/],
		["image/gif", /^R0lGOD[dl]h/],
		["image/webp", /^UklG.{8}RUJQ/],
	];

	function image(value) {
		const url = imageUrl(value);
		if (url === "") throw new TypeErrorCtor(${JSON.stringify(ie)});
		const colon = url.indexOf(":");
		const scheme = colon === -1 ? "" : url.slice(0, colon).toLowerCase();
		if (scheme === "http" || scheme === "https") {
			throw new TypeErrorCtor("remote image URLs are not supported in tool outputs. Pass a base64 data URI instead");
		}
		const comma = url.indexOf(",");
		const header = comma === -1 ? [] : url.slice(colon + 1, comma).split(";");
		if (scheme !== "data" || comma === -1 || header.slice(1).every((part) => part.toLowerCase() !== "base64")) {
			throw new TypeErrorCtor("invalid image output. Pass a base64 data URI instead");
		}
		// Providers reject the whole request on a bad image, and a persisted image block would be
		// resent on every later turn. Line breaks from wrapped base64 are dropped. The declared type
		// is ignored in favor of the detected one, as providers also reject mismatches.
		const data = url.slice(comma + 1).replace(/\\s+/g, "");
		if (data.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
			throw new TypeErrorCtor("invalid image output. The image data is not valid base64 (truncated or corrupted?)");
		}
		const head = data.slice(0, 16);
		const signature = IMAGE_SIGNATURES.find(([, pattern]) => pattern.test(head));
		if (!signature) {
			throw new TypeErrorCtor("invalid image output. The image data is not a PNG, JPEG, GIF, or WebP image");
		}
		output("image", data, signature[0]);
	}

	function exit() {
		let writesJson;
		try {
			writesJson = serializeWrites();
		} catch (error) {
			done(false, describeError(error));
			throw EXIT;
		}
		done(true, undefined, writesJson);
		throw EXIT;
	}

	const console = {};
	for (const level of ["log", "info", "warn", "error", "debug"]) {
		console[level] = (...args) => {
			output("console", args.map(format).join(" "));
		};
	}
	Object.freeze(console);

	Object.defineProperty(globalThis, "tools", { value: toolsProxy, enumerable: true });
	Object.defineProperty(globalThis, "ALL_TOOLS", { value: allTools, enumerable: true });
	Object.defineProperty(globalThis, "console", { value: console, enumerable: true });
	Object.defineProperty(globalThis, "text", { value: text, enumerable: true });
	Object.defineProperty(globalThis, "image", { value: image, enumerable: true });
	Object.defineProperty(globalThis, "exit", { value: exit, enumerable: true });

	return {
		settle(id, ok, payload, propertiesJson) {
			const entry = pending.get(id);
			if (!entry) return;
			pending.delete(id);
			if (!ok) {
				const error = new ErrorCtor(payload);
				if (propertiesJson !== undefined) {
					const properties = parse(propertiesJson);
					for (const key of Object.keys(properties)) {
						if (key === "name" || key === "message" || key === "stack") continue;
						Object.defineProperty(error, key, { value: properties[key], writable: true, enumerable: true, configurable: true });
					}
				}
				entry.reject(error);
				return;
			}
			let value;
			try {
				value = payload === undefined ? undefined : parse(payload);
			} catch (error) {
				entry.reject(error);
				return;
			}
			entry.resolve(value);
		},
		run(fn) {
			let promise;
			try {
				promise = fn(toolsProxy, console);
			} catch (error) {
				done(false, describeError(error));
				return;
			}
			promiseThen.call(
				promise,
				(value) => {
					let json;
					try {
						json = serialize(value);
					} catch (error) {
						done(false, describeError(error));
						return;
					}
					done(true, json, serializeWrites());
				},
				(error) => {
					done(false, describeError(error));
				},
			);
		},
		stalled() {
			if (finished || pending.size > 0) return false;
			done(
				false,
				stringify({
					name: "Error",
					message:
						"The script is waiting on a promise that can never settle: no tool call is pending, and timers do not exist here.",
				}),
			);
			return true;
		},
	};
})`;var at=1;function lt(n){let e=2166136261;for(let t=0;t<n.length;t++)e^=n.charCodeAt(t),e=Math.imul(e,16777619);return(e>>>0).toString(16).padStart(8,"0")}f(lt,"fnv1a");var ct=lt(Ee);function ut(n){let e=n>>>0;return()=>{e=e+1831565813>>>0;let t=Math.imul(e^e>>>15,1|e);return t=t+Math.imul(t^t>>>7,61|t)^t,(t^t>>>14)>>>0}}f(ut,"prng");function ft(n){let e=ut(n.seed^2654435769);return t=>({...Le(t),clock_time_get(r,s,o){let i;return n.creating?i=r===0?BigInt(n.seed+1)*1000n:0n:r===0?i=BigInt(Math.round(n.now))*1000000n:i=BigInt(Math.round(n.now-n.startedAt))*1000000n,new DataView(t.buffer).setBigUint64(o,i,!0),0},random_get(r,s){let o=new Uint8Array(t.buffer,r,s);for(let i=0;i<s;i+=4){let a=e();for(let l=0;l<4&&i+l<s;l++)o[i+l]=a>>>l*8}return 0}})}f(ft,"deterministicWasi");function Le(n){return{fd_write(e,t,r,s){let o=new DataView(n.buffer),i=0;for(let a=0;a<r;a++)i+=o.getUint32(t+a*8+4,!0);return o.setUint32(s,i,!0),0}}}f(Le,"discardOutput");function dt(n){let e=n.message?`${n.name}: ${n.message}`:n.name,t=n.stack?.trimEnd();return JSON.stringify({name:n.name,message:n.message,stack:t?`${e}
${t}`:e})}f(dt,"describeException");var pt=50;function De(n){return{type:"crash",message:n instanceof Error?`${n.name}: ${n.message}`:String(n)}}f(De,"crashMessage");async function He(n){let{data:e,post:t}=n,r=n.maxStackSize??ne,s=e.deterministic,o=s&&{creating:!0,startedAt:s.startedAt,now:s.startedAt,seed:s.seed>>>0},i=await oe.create({wasm:n.wasm,memoryLimit:e.memoryLimitBytes,maxStackSize:r,interruptHandler:n.shouldInterrupt,wasi:o?ft(o):Le,...o?{timezoneOffset:0,intrinsics:Se.ALL&~Se.WEAK_REF}:{}});o&&(o.creating=!1);let a=!1,l=0,u=1,c=0,d=new Map,p=f(g=>{i.withScope(()=>{i.callFunction(y,m,i.newNumber(g.id),g.ok?i.true:i.false,g.payload===void 0?i.undefined:i.newString(g.payload),g.properties===void 0?i.undefined:i.newString(g.properties))}),S()},"apply"),_={deliver(g){if(!a)try{if(!o){p(g);return}let{seq:h}=g;if(h===void 0||!Number.isInteger(h)||h<u||d.has(h))throw new Error(`Result ${g.id} has sequence number ${h}, expected ${u} or later, once`);d.set(h,g);for(let x=d.get(u);x!==void 0;x=d.get(u))d.delete(u),x.now!==void 0&&Number.isFinite(x.now)&&(o.now=Math.max(o.now,x.now)),c=u,p(x),t({type:"idle",seq:u,issued:l}),u++}catch(h){t(De(h))}},dispose(){a||(a=!0,i.dispose())}},m,y,E,k=i._getExports(),S=f(()=>{let g=0;for(;k.qjs_is_job_pending();){if(k.qjs_execute_pending_job()<0)throw new Error("Promise job failed");if(++g%pt===0&&n.shouldInterrupt())throw new Error("Execution interrupted")}i.callFunction(E,m).dispose()},"drain");try{let g=i.newFunction("bridge",(v,O,T,w)=>{switch(v.toString()){case"call":case"global":l++,t({type:"call",id:O.toNumber(),target:v.toString()==="call"?"tool":"global",name:T.toString(),args:w===void 0||w.isUndefined?void 0:w.toString()});break;case"output":t({type:"output",item:O.toString()==="image"?{type:"image",data:T.toString(),mimeType:w.toString()}:O.toString()==="console"?{type:"text",text:T.toString(),console:!0}:{type:"text",text:T.toString()}});break;case"done":{let j=o?{during:{seq:c,issued:l}}:{};O.toBoolean()?t({type:"done",ok:!0,value:T===void 0||T.isUndefined?void 0:T.toString(),writes:w.toString(),...j}):t({type:"done",ok:!1,error:T.toString(),...j});break}}return i.undefined});m=i.withScope(v=>v.escape(i.callFunction(i.evalCode(Ee,"codemode-prelude.js"),i.undefined,g,i.newString(JSON.stringify(e.tools)),i.newString(JSON.stringify(e.globals)),i.newString(JSON.stringify(e.store))))),y=m.getProp("settle");let h=m.getProp("run");if(E=m.getProp("stalled"),o){let v=i.versions,O=n.interruptBudget??"none";t({type:"started",fingerprint:`quickjs-wasi ${v["quickjs-wasi"]}, quickjs ${v.quickjs}, prelude ${ct}, deterministic ${at}, stack ${r}, heap ${e.memoryLimitBytes??"none"}, budget ${O}`})}let x;try{x=i.evalCode(`(async (tools, console) => {${e.code}
})`,"codemode.js")}catch(v){if(!(v instanceof B))throw v;return t({type:"done",ok:!1,error:dt(v)}),_}i.callFunction(h,m,x).dispose(),x.dispose(),S(),o&&t({type:"idle",seq:0,issued:l})}catch(g){t(De(g))}return _}f(He,"startVm");var G=1e5,mt=256*1024;function $e(n,e=G){return async(t,r)=>{let s;try{s=await n}catch(c){throw new Error(`Failed to load QuickJS: ${re(c)}`)}let o=!1,i=!1,a=0,l=!1,u=await He({data:t,wasm:s,maxStackSize:mt,interruptBudget:e,shouldInterrupt:f(()=>o||i||l?!0:++a<=e?!1:(l=!0,!0),"shouldInterrupt"),post:f(c=>{let d=c.type==="done"||c.type==="crash";d&&i||(d&&(i=!0),queueMicrotask(()=>{if(!o){if(l&&(c.type==="done"||c.type==="crash")){r.failure({kind:"timeout",message:`Execution exceeded its interrupt budget of ${e}`});return}r.message(c)}}))},"post")});return{post:f(c=>{o||u.deliver(c)},"post"),stop:f(async()=>{o||(o=!0,u.dispose())},"stop")}}}f($e,"inlineLauncher");var ht=1e3,gt=1<<20;function je(n,e,t){let r=t.maxInterruptBudget??G,s=Math.min(n.interruptBudget??r,r),o=n.data.memoryLimitBytes,i=t.maxMemoryLimitBytes,a=o===void 0?i:i===void 0?o:Math.min(o,i),l={...n.data,memoryLimitBytes:a};return new Promise(u=>{let c,d=!1,p=[],_=0,m=[],y=f(()=>{let h=p;return p=[],_=0,h},"takeBuffer"),E=f(h=>{if(d)return;d=!0;let x=y();(h?e([...x,h]).catch(()=>null):Promise.resolve()).then(()=>c?.stop()).catch(()=>{}).then(()=>u())},"end"),k=f(h=>{if(!(d||h===null)){if(h.type==="stop"){E(void 0);return}c?c.post(h):m.push(h)}},"reply"),S=f(h=>{if(d)return;let x=h;switch(x.type){case"output":{p.push(x),_+=x.item.type==="text"?x.item.text.length:x.item.data.length,(p.length>=ht||_>=gt)&&e(y()).then(k,()=>E(void 0));break}case"started":p.push(x);break;case"call":case"idle":e([...y(),x]).then(k,()=>E(void 0));break;default:E(x)}},"onMessage"),g=$e(t.wasm,s);Promise.resolve(g(l,{message:S,failure:f(h=>E({type:"failure",error:h}),"failure")})).then(h=>{if(c=h,d){h.stop().catch(()=>{});return}for(let x of m.splice(0))h.post(x)},h=>E({type:"failure",error:{kind:"sandbox",message:re(h)}}))})}f(je,"serveCodemodeRemote");var Ae=globalThis.__native,ke=new Map;function wt(n){let e=ke.get(n);return e===void 0&&(e=WebAssembly.compile(Ae.fsReadFile(n)),ke.set(n,e),e.catch(()=>ke.delete(n))),e}f(wt,"quickJS");var _t=1,Y=new Map;globalThis.__worker={serve(n,e){let t=JSON.parse(n),r=f(o=>new Promise(i=>{let a=_t++;Y.set(a,i),Ae.exchange(a,JSON.stringify(o))}),"exchange"),s=t.interruptBudget??G;je(t,r,{wasm:wt(e),maxInterruptBudget:s}).finally(()=>{for(let o of Y.values())o({type:"stop"});Y.clear(),Ae.done()})},reply(n,e){let t=Y.get(n);t!==void 0&&(Y.delete(n),t(JSON.parse(e)))}};})();
