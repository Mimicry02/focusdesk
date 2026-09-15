// Keep polling reads side-effect free: recurrence generation runs on normal loads.
export const taskSnapshot=tasks=>tasks.map(t=>t.id+':'+t.version).sort().join('|');
export async function fetchTasks(api,sync=false){
 const tasks=[];
 for(let page=0;page<=1000;page++){
  const data=await api('tasks?page='+page+(sync?'&sync=1':''));
  tasks.push(...data.tasks);
  if(!data.hasMore)return tasks;
 }
 throw Error('Data terlalu banyak; hubungi admin.');
}
