import {sb,HttpError} from './core.js';
export function wibDay(){return new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
export async function sendDigest(userId){
 if(!process.env.RESEND_API_KEY||!process.env.EMAIL_FROM)throw new HttpError(503,'RESEND_API_KEY dan EMAIL_FROM belum dikonfigurasi');
 const p=(await sb('/rest/v1/fd_profiles?id=eq.'+userId+'&is_active=eq.true&select=*',{admin:true}))[0];if(!p)throw new HttpError(403,'Akun tidak aktif');
 const u=await sb('/auth/v1/admin/users/'+userId,{admin:true});if(!u.email_confirmed_at)throw new HttpError(409,'Email akun belum terverifikasi');
 const day=wibDay();const claimed=await sb('/rest/v1/rpc/fd_claim_digest',{method:'POST',admin:true,data:{p_user:userId,p_day:day}});if(!claimed)return{status:'skipped',message:'Briefing hari ini sudah diproses atau sedang dikirim.'};
 const path='/rest/v1/fd_deliveries?user_id=eq.'+userId+'&day=eq.'+day;
 try{
  const rows=await sb('/rest/v1/fd_tasks?user_id=eq.'+userId+'&status=neq.Done&or=(scheduled_date.eq.'+day+',due_date.lt.'+day+')&select=title,category,start_time,duration,scheduled_date,due_date,top_focus&order=start_time.asc.nullslast&limit=500',{admin:true});
  const today=rows.filter(t=>t.scheduled_date===day),late=rows.filter(t=>t.due_date&&t.due_date<day),top=today.filter(t=>t.top_focus);
  const text=`Halo ${p.display_name||'Anda'},\n\nRencana ${day} (WIB)\n\nTOP PRIORITIES\n${top.map(t=>'- '+t.title).join('\n')||'Belum dipilih'}\n\nJADWAL HARI INI\n${today.map(t=>`${t.start_time?.slice(0,5)||'Fleksibel'} · ${t.title} (${t.duration} menit) · ${t.category}`).join('\n')||'Belum ada tugas terjadwal'}\n\nTERLAMBAT\n${late.map(t=>'- '+t.title+' · deadline '+t.due_date).join('\n')||'Tidak ada'}\n\nBuka workspace: ${process.env.APP_URL}\nMatikan briefing melalui Settings di aplikasi.\n${rows.length===500?'Daftar dibatasi 500 tugas. Buka aplikasi untuk semua tugas.':''}`;
  const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+process.env.RESEND_API_KEY,'Content-Type':'application/json','Idempotency-Key':`focusdesk-${userId}-${day}`},body:JSON.stringify({from:process.env.EMAIL_FROM,to:[u.email],subject:`Focusdesk · Rencana ${day}`,text}),signal:AbortSignal.timeout(15000)});
  const data=await r.json();if(!r.ok)throw new HttpError(502,'Penyedia email menolak pengiriman. Periksa domain pengirim dan konfigurasi Resend.');
  await sb(path,{method:'PATCH',admin:true,data:{status:'accepted',accepted_at:new Date().toISOString(),provider_id:data.id,last_error:null}});
  return{status:'accepted',message:'Briefing diterima penyedia email. Periksa inbox/spam; status ini bukan bukti email sudah masuk inbox.'};
 }catch(e){try{await sb(path,{method:'PATCH',admin:true,data:{status:'failed',last_error:'Pengiriman gagal; periksa konfigurasi atau coba lagi.'}})}catch{}throw e;}
}
