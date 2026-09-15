export const STATUSES=['Backlog','To do','In progress','Ready for Testing','Testing','Rework','Done'];
export function actions(task,owner=true,executor=true){
 if(!task.requires_testing)return executor?(task.status==='Done'?[['todo','Reopen']]:[...(task.status==='In progress'?[]:[['start','Start work']]),['done','Done']]):[];
 if(['Backlog','To do','Rework'].includes(task.status))return executor?[['start','Start work']]:[];
 if(task.status==='In progress')return executor?[['ready','Need Testing']]:[];
 if(!owner)return [];
 if(task.status==='Ready for Testing')return [['test','Start testing'],['fail','Return to PIC']];
 if(task.status==='Testing')return [['done','Pass & close'],['fail','Fail & return']];
 if(task.status==='Done')return [['fail','Reopen with reason']];
 return [];
}
export function roleFor(task,user){return {owner:task.user_id===user,executor:task.assignee_id===user||(!task.pic_id&&task.user_id===user)};}
export const actionStatus={start:'In progress',ready:'Ready for Testing',test:'Testing',done:'Done',fail:'Rework',todo:'To do'};
