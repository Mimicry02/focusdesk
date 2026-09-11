export const CATEGORIES=['Full Time','Property','Web Development'];
export const colors={'Full Time':'blue',Property:'orange','Web Development':'purple'};
export const escapeHTML=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function today(){return new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
export function shift(day,n){const d=new Date(day+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10);}
export function startWeek(day){return shift(day,-((new Date(day+'T12:00:00Z').getUTCDay()+6)%7));}
export const mins=t=>{const [h,m]=t.split(':').map(Number);return h*60+m};
export const clock=n=>`${String(Math.floor(n/60)%24).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`;
export const hours=n=>`${Math.floor(n/60)?Math.floor(n/60)+'j ':''}${n%60?n%60+'m':n===0?'0j':''}`.trim();
export function fresh(day=today()){return{id:crypto.randomUUID(),title:'',category:'Full Time',project:'',kind:'Delivery',priority:'Medium',status:'To do',due_date:day,scheduled_date:day,start_time:'',duration:60,notes:'',top_focus:false,repeat_pattern:'once',repeat_interval:1,repeat_end_date:''};}
export const executor=t=>t.assignee_id?'user:'+t.assignee_id:t.pic_id?'email:'+String(t.pic_email||t.pic_id).toLowerCase():'user:'+(t.user_id||'self');
export function conflicts(t,tasks){if(!t.start_time||!t.scheduled_date||t.status==='Done')return[];return tasks.filter(x=>x.id!==t.id&&executor(x)===executor(t)&&x.status!=='Done'&&x.scheduled_date===t.scheduled_date&&x.start_time&&mins(x.start_time)<mins(t.start_time)+t.duration&&mins(t.start_time)<mins(x.start_time)+x.duration)}
export function googleLink(t){const start=new Date(`${t.scheduled_date}T${t.start_time?.slice(0,5)||'09:00'}:00+07:00`);const stamp=d=>d.toISOString().replace(/[-:]|\.\d{3}/g,'');return 'https://calendar.google.com/calendar/render?'+new URLSearchParams({action:'TEMPLATE',text:t.title,dates:stamp(start)+'/'+stamp(new Date(+start+t.duration*60000)),details:t.category+' · '+t.project+'\n'+t.notes,ctz:'Asia/Jakarta'});}
export function ics(tasks){const esc=s=>String(s||'').replace(/\\/g,'\\\\').replace(/\r?\n/g,'\\n').replace(/,/g,'\\,').replace(/;/g,'\\;');const stamp=d=>d.toISOString().replace(/[-:]|\.\d{3}/g,'');const lines=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//Focusdesk//Planner//ID',...tasks.filter(t=>t.scheduled_date&&t.status!=='Done').flatMap(t=>{const start=new Date(`${t.scheduled_date}T${t.start_time?.slice(0,5)||'09:00'}:00+07:00`);return['BEGIN:VEVENT','UID:'+t.id+'@focusdesk','DTSTAMP:'+stamp(new Date()),'DTSTART:'+stamp(start),'DTEND:'+stamp(new Date(+start+t.duration*60000)),'SUMMARY:'+esc(t.title),'DESCRIPTION:'+esc(t.category+' · '+t.notes),'END:VEVENT']}),'END:VCALENDAR'];
 // Fold at <=73 UTF-8 bytes, preserving multibyte characters and RFC 5545 continuation.
 return lines.map(line=>{let chunks=[],buf='',size=0;for(const ch of line){const n=new TextEncoder().encode(ch).length;if(size+n>73){chunks.push(buf);buf='';size=0;}buf+=ch;size+=n;}chunks.push(buf);return chunks.join('\r\n ')}).join('\r\n')+'\r\n';}
