// Markdown is treated as data, never executed or rendered as trusted HTML.
export function chunks(md,title='Guide') {
 if(typeof md!=='string'||!md.trim()||md.length>150000)throw Error('Markdown wajib diisi, maksimal 150.000 karakter.');
 const out=[];let heading=title.slice(0,160),lines=[];
 const flush=()=>{let content=lines.join('\n').trim();while(content){let end=Math.min(content.length,2200);if(end<content.length){const at=content.lastIndexOf('\n',end);if(at>1000)end=at;}out.push({heading,content:content.slice(0,end),position:out.length});content=content.slice(end).trim();}lines=[];};
 for(const line of md.split(/\r?\n/)){const m=/^#{1,6}\s+(.+)/.exec(line);if(m){flush();heading=m[1].slice(0,160);}lines.push(line);}flush();
 if(out.length>200)throw Error('Maksimal 200 bagian dokumen. Pecah menjadi beberapa artikel.');return out;
}
const stop=new Set('bagaimana gimana cara saya aku kami kita anda kamu mereka dia yang dan atau untuk dari dengan pada di ke ini itu ada apakah bisa boleh mau ingin tolong dong ya yah sih nya buat membuat melakukan mohon the a an how do i can you to in on for of is are please what'.split(' '));
export function terms(q){return [...new Set(String(q).toLowerCase().match(/[\p{L}\p{N}_-]+/gu)||[])].filter(x=>x.length>=2&&x.length<=40&&!stop.has(x)).slice(0,12);}
export function askInput(text){const m=/^\/ask(?:@([A-Za-z0-9_]+))?\s+([\s\S]+)$/i.exec(text.trim());return m?{address:m[1],input:m[2].trim()}:null;}
export function deskCallback(s){const m=/^k:([0-9a-f-]{36}):(ok|more|escalate|confirm|cancel|status|c[0-9a-f]{8})$/.exec(s||'');return m?{request:m[1],action:m[2]}:null;}
