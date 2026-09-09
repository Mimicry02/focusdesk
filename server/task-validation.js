import {HttpError} from './core.js';
export const categories=['Full Time','Property','Web Development'];
function enumeration(v,values,label){if(!values.includes(v))throw new HttpError(400,label+' tidak valid');return v;}
function text(v,max,required=false){if(typeof v!=='string'||v.length>max||required&&!v.trim())throw new HttpError(400,'Teks tugas tidak valid');return v.trim();}
function date(v){if(!v)return null;if(typeof v!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(v))throw new HttpError(400,'Tanggal tidak valid');const d=new Date(v+'T12:00:00Z');if(Number.isNaN(+d)||d.toISOString().slice(0,10)!==v)throw new HttpError(400,'Tanggal tidak valid');return v;}
export function validateTask(b){
 const t={title:text(b.title,180,true),category:enumeration(b.category,categories,'Kategori'),project:text(b.project||'',100),kind:enumeration(b.kind,['Delivery','Meeting','Marketing','Follow-up'],'Jenis'),priority:enumeration(b.priority,['High','Medium','Low'],'Prioritas'),status:enumeration(b.status,['Backlog','To do','In progress','Done'],'Status'),due_date:date(b.due_date),scheduled_date:date(b.scheduled_date),start_time:b.start_time||null,duration:Number(b.duration),notes:text(b.notes||'',4000),top_focus:b.top_focus===true};
 if(!Number.isInteger(t.duration)||t.duration<5||t.duration>720)throw new HttpError(400,'Durasi harus 5–720 menit');
 if(t.start_time){if(typeof t.start_time!=='string'||!/^([01]\d|2[0-3]):[0-5]\d(:00)?$/.test(t.start_time))throw new HttpError(400,'Jam tidak valid');t.start_time=t.start_time.slice(0,5);if(!t.scheduled_date)throw new HttpError(400,'Isi tanggal pengerjaan');const[h,m]=t.start_time.split(':').map(Number);if(h*60+m+t.duration>1440)throw new HttpError(400,'Sesi tidak boleh melewati tengah malam');}
 if(t.top_focus&&!t.scheduled_date)throw new HttpError(400,'Prioritas utama harus memiliki tanggal pengerjaan');return t;
}
