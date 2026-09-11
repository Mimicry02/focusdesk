import ExcelJS from 'exceljs';
import {columns,rowValues,basisLabels,scopeLabels} from './report.js';
const green='FF286246',pale='FFEDF5EE',ink='FF304638';
function header(row){row.font={name:'Calibri',size:11,bold:true,color:{argb:'FFFFFFFF'}};row.fill={type:'pattern',pattern:'solid',fgColor:{argb:green}};row.alignment={vertical:'middle',wrapText:true};row.height=32;}
export async function workbookReport(r){
 const w=new ExcelJS.Workbook();w.creator='Focusdesk';w.created=new Date(r.generatedAt);w.calcProperties.fullCalcOnLoad=true;
 const s=w.addWorksheet('Summary',{views:[{showGridLines:false}]});s.columns=[{width:34},{width:44},{width:16},{width:18}];
 s.mergeCells('A1:D1');s.getCell('A1').value='Monthly work report';s.getCell('A1').font={name:'Calibri',size:20,bold:true,color:{argb:ink}};s.getRow(1).height=34;
 const picLabel=r.filters.pic==='all'?'Semua PIC':r.filters.pic==='self'?'Pemilik tugas (tanpa PIC eksternal)':r.summary.byPic[0]?.name||'PIC terpilih (tidak ada tugas)';
 const meta=[['Period',r.filters.month],['Period basis',basisLabels[r.filters.basis]],['Scope',scopeLabels[r.filters.scope]],['Category',r.filters.category==='all'?'Semua kategori':r.filters.category],['PIC',picLabel],['Prepared by',r.owner],['Generated (WIB)',new Date(r.generatedAt).toLocaleString('sv-SE',{timeZone:'Asia/Jakarta'})]];
 for(const x of meta)s.addRow(x);s.addRow([]);s.mergeCells('A10:D11');s.getCell('A10').value='Status dan PIC merupakan data terkini saat ekspor, bukan kondisi historis pada akhir bulan. Estimated minutes bukan jam kerja aktual. Simpan ekspor akhir bulan sebagai arsip.';s.getCell('A10').alignment={wrapText:true,vertical:'middle'};s.getCell('A10').font={size:11,color:{argb:'FF687C6C'}};s.getRow(10).height=28;s.getRow(11).height=26;
 header(s.addRow(['Metric','Value']));
 const n=r.rows.length,last=n+1;const statuses={done:'Done',inProgress:'In progress',toDo:'To do',backlog:'Backlog',readyForTesting:'Ready for Testing',testing:'Testing',rework:'Rework'};
 s.addRow(['Tasks in period',n]);for(const [key,status] of Object.entries(statuses)){s.addRow([`Current status: ${status}`,n?{formula:`COUNTIF(Tasks!K2:K${last},"${status}")`,result:r.summary[key]}:0]);}
 s.addRow(['Overdue at export (WIB)',r.summary.overdueNow]);s.addRow(['Estimated minutes',n?{formula:`SUM(Tasks!O2:O${last})`,result:r.summary.minutes}:0]);s.addRow(['Estimated hours',{formula:`B${s.rowCount}/60`,result:r.summary.minutes/60}]);s.getCell(`B${s.rowCount}`).numFmt='0.0';s.addRow([]);
 header(s.addRow(['PIC','Email','Tasks','Estimated minutes']));for(const g of r.summary.byPic)s.addRow([g.name,g.email,g.tasks,g.minutes]);s.addRow([]);header(s.addRow(['Category','Tasks','Done now','Estimated minutes']));for(const g of r.summary.byCategory)s.addRow([g.name,g.tasks,g.done,g.minutes]);
 s.eachRow(row=>{row.eachCell(c=>{if(!c.font?.bold)c.font={name:'Calibri',size:11,color:{argb:ink}};c.alignment={...c.alignment,vertical:'middle',wrapText:true};});if(!row.height)row.height=28});
 s.pageSetup={paperSize:9,orientation:'portrait',fitToPage:true,fitToWidth:1,fitToHeight:0};
 const t=w.addWorksheet('Tasks',{views:[{state:'frozen',xSplit:2,ySplit:1}],pageSetup:{orientation:'landscape',paperSize:9,fitToPage:true,fitToWidth:1,fitToHeight:0,printTitlesRow:'1:1'}});
 const widths=[38,44,21,25,16,24,32,24,32,13,16,16,16,18,19,23,48,55,12];t.columns=columns.map((name,i)=>({header:name,key:String(i),width:widths[i]||24}));header(t.getRow(1));
 for(const task of r.rows){const values=rowValues(task);for(const index of [11,12])if(values[index])values[index]=new Date(values[index]+'T00:00:00Z');if(task.completed_at)values[15]=new Date(+new Date(task.completed_at)+7*3600000);const row=t.addRow(values);row.height=60;row.alignment={vertical:'top',wrapText:true};row.font={name:'Calibri',size:11,color:{argb:ink}};if(row.number%2===0)row.fill={type:'pattern',pattern:'solid',fgColor:{argb:pale}};}
 t.getColumn(12).numFmt='dd mmm yyyy';t.getColumn(13).numFmt='dd mmm yyyy';t.getColumn(16).numFmt='dd mmm yyyy hh:mm';t.getColumn(15).numFmt='#,##0';t.getColumn(19).numFmt='0';t.autoFilter={from:{row:1,column:1},to:{row:Math.max(1,n+1),column:columns.length}};
 t.headerFooter.oddFooter='Focusdesk | &P / &N';s.headerFooter.oddFooter='Focusdesk | &P / &N';
 return Buffer.from(await w.xlsx.writeBuffer());
}
