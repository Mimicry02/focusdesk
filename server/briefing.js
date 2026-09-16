// Shared formatter. SQL owns date scoping and full counts; message samples stay bounded.
const html=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function briefingText(data,slot,day,app){
 const morning=slot==='morning';
 const sections=[['carry','Tertunda sebelum hari ini'],['today',morning?'Rencana hari ini':'Hari ini belum selesai'],...(!morning?[['tomorrow','Agenda besok']]:[])];
 const lines=sections.map(([key,title])=>{
  const b=data[key]||{count:0,items:[]};
  return `<b>${title} (${b.count})</b>\n`+(b.items.length?b.items.slice(0,5).map((t,i)=>`${i+1}. ${html(t.title.slice(0,80))}\n${html(t.status)} · PIC ${html((t.pic_name||t.owner_name||'Pemilik').slice(0,30))}\nJadwal ${html(t.scheduled_date||'—')} · Due ${html(t.due_date||'—')}`).join('\n\n'):'Tidak ada tugas terbuka.')+(b.count>b.items.length?'\n… daftar dipersingkat; lihat semua di Focusdesk.':'');
 });
 return `<b>Focusdesk · ${morning?'Briefing pagi 09.00':'Evaluasi sore 17.30'} WIB</b>\n${html(day)} · status saat pesan disiapkan\n\n`+lines.join('\n\n')+
 (morning?'\n\nKartu tindakan tugas hari ini/tertunda dikirim ke DM PIC; task siap diuji ke DM reviewer.':'\n\nBelum selesai mencakup task yang menunggu testing. Agenda besok dapat memuat task tertunda yang dijadwalkan ulang.')+
 `\nHanya task yang dibagikan ke grup ini.\n<a href="${html(app)}">Buka Focusdesk</a>`;
}
export function scheduledExpired(o,now=new Date()){
 if(!o.schedule_slot)return false;
 const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(now);
 const p=Object.fromEntries(parts.map(x=>[x.type,x.value]));const d=`${p.year}-${p.month}-${p.day}`;
 return o.day!==d||o.schedule_slot==='morning'&&`${p.hour}:${p.minute}`>='17:30';
}
