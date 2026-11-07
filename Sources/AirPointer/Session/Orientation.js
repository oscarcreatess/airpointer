// Raw body-to-reference orientation for the closed-case pointer, and the grip that maps it onto the screen.
export const dot=(a,b)=>a.reduce((sum,x,i)=>sum+x*b[i],0);
export const norm=a=>Math.sqrt(dot(a,a));
export const unit=a=>a.map(x=>x/norm(a));
export const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
export const inverse=q=>[q[0],-q[1],-q[2],-q[3]];
export function multiply(a,b){return [
 a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3],
 a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2],
 a[0]*b[2]-a[1]*b[3]+a[2]*b[0]+a[3]*b[1],
 a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0]];}
export const rotate=(q,v)=>multiply(multiply(q,[0,...v]),inverse(q)).slice(1);
export function rotation(q){
 if(q[0]<0)q=q.map(x=>-x);
 const n=norm(q.slice(1));return n<1e-10?[0,0,0]:q.slice(1).map(x=>x*2*Math.atan2(n,q[0])/n);
}

// Still stretches measure the gyro's resting offset. The first, before any offset is known, allows a
// hand-held hold; later ones keep a warm sensor's offset current, so they must be steadier.
const firstStill={span:1.2,gyro:.8,accel:.03},steadyStill={span:1.8,gyro:.35,accel:.015};

export class Orientation {
 // A saved offset barely moves between connections, so it is used in any pose without a wait.
 constructor(seed=null){
  const valid=a=>Array.isArray(a)&&a.length===3&&a.every(Number.isFinite);
  this.seed=seed&&valid(seed.bias)&&norm(seed.bias)<5?{bias:[...seed.bias]}:null;
  this.measured=0;this.reset();
 }
 reset(){
  this.q=[1,0,0,0];this.bias=[0,0,0];this.accel=null;this.referenceGravity=null;
  this.last={};this.window=[];this.ready=false;this.seedUsed=false;this.generation=(this.generation||0)+1;
 }
 settling(){
  const span=firstStill.span;
  if(this.ready)return {seconds:span,span,progress:1,message:'Ready'};
  if(this.window.length<2)return {seconds:0,span,progress:0,message:'Set the case down'};
  const mean=key=>[0,1,2].map(i=>this.window.reduce((sum,x)=>sum+x[key][i],0)/this.window.length);
  const bias=mean('vector'),gravity=mean('g');
  const spread=(key,center)=>Math.sqrt(this.window.reduce((sum,x)=>sum+norm(x[key].map((v,i)=>v-center[i]))**2,0)/this.window.length);
  const stable=spread('vector',bias)<=firstStill.gyro&&spread('g',gravity)<=firstStill.accel;
  const seconds=stable?Math.min(span,(this.window.at(-1).stamp-this.window[0].stamp)*1e-6):0;
  return {seconds,span,progress:seconds/span,message:stable?'Keep it still':'Movement detected — keep it still'};
 }
 // The mean of a still stretch is the gyro's resting offset; any movement starts the stretch over.
 still(stamp,vector,g,magnitude,limits){
  if(magnitude<.85||magnitude>1.15||norm(vector)>5){this.window=[];return null;}
  this.window.push({stamp,vector,g});
  while(this.window.length>1&&stamp-this.window[0].stamp>(limits.span+.4)*1e6)this.window.shift();
  if(stamp-this.window[0].stamp<limits.span*1e6)return null;
  const mean=key=>[0,1,2].map(i=>this.window.reduce((s,x)=>s+x[key][i],0)/this.window.length);
  const bias=mean('vector'),gravity=mean('g');
  const spread=(key,center)=>Math.sqrt(this.window.reduce((s,x)=>s+norm(x[key].map((v,i)=>v-center[i]))**2,0)/this.window.length);
  if(spread('vector',bias)>limits.gyro||spread('g',gravity)>limits.accel)return null;
  this.window=[];return {bias,gravity};
 }
 feed(row){
  const [,service,stamp,host,...raw]=row;
  if(![11,12].includes(service)||!Number.isFinite(stamp)||stamp<=0||
     !Number.isFinite(host)||raw.length!==3||!raw.every(Number.isFinite))return false;
  const previous=this.last[service];if(previous&&stamp<=previous.stamp)return false;
  const dt=previous?(stamp-previous.stamp)*1e-6:0;
  // A drop under two seconds holds the last pose rather than integrating across it; a longer one starts over.
  if(previous&&dt>.2){if(this.ready&&dt<2)this.last[service]={stamp,host};else this.reset();return false;}
  this.last[service]={stamp,host};
  const vector=raw.map(x=>x*1e-5);
  if(service===11){this.accel={vector,stamp};return false;}
  if(!this.accel||Math.abs(stamp-this.accel.stamp)>100000)return false;
  const g=this.accel.vector, magnitude=norm(g);
  if(!this.ready){
   // The reference pose comes from the first calm sample, so the wait is only for a first offset.
   if(this.seed&&magnitude>.95&&magnitude<1.05&&norm(vector.map((v,i)=>v-this.seed.bias[i]))<20){
    this.bias=[...this.seed.bias];this.referenceGravity=unit(g);this.ready=true;this.seedUsed=true;this.window=[];return true;
   }
   const still=this.still(stamp,vector,g,magnitude,firstStill);
   if(!still)return false;
   this.bias=still.bias;this.referenceGravity=unit(still.gravity);this.seed={bias:still.bias};this.measured++;this.ready=true;
   return true;
  }
  // A steadier stretch moves the offset halfway, at most 0.1°/s, so a slow steady turn can't pass for it.
  const still=this.still(stamp,vector,g,magnitude,steadyStill);
  if(still){
   const step=still.bias.map((x,i)=>x-this.bias[i]),k=Math.min(.5,.1/Math.max(norm(step),1e-9));
   this.bias=this.bias.map((x,i)=>x+step[i]*k);this.seed={bias:[...this.bias]};this.measured++;
  }
  if(dt<=0)return false;
  const omega=vector.map((x,i)=>(x-this.bias[i])*Math.PI/180);
  const advance=rate=>{
   const speed=norm(rate),angle=speed*dt;
   const delta=speed<1e-10?[1,0,0,0]:[Math.cos(angle/2),...rate.map(x=>x/speed*Math.sin(angle/2))];
   this.q=unit(multiply(this.q,delta));
  };
  advance(omega);
  if(magnitude>.85&&magnitude<1.15){
   const expected=rotate(inverse(this.q),this.referenceGravity);
   const correction=cross(unit(g),expected);
   advance(correction.map(x=>x*.5));
  }
  return true;
 }
}

export class Grip {
 // Edges saved from an earlier calibration still hold in the case's own frame, so after a reconnect
 // only the center is new. Gravity in that frame tells whether the case is held the same way.
 constructor(saved=null){
  this.center=null;this.right=null;this.up=null;this.gravity=null;
  const valid=(a,low,high)=>Array.isArray(a)&&a.length===3&&a.every(Number.isFinite)&&norm(a)>=low&&norm(a)<=high;
  const edge=a=>valid(a,5*Math.PI/180,80*Math.PI/180);
  if(saved&&edge(saved.right)&&edge(saved.up)&&valid(saved.gravity,.99,1.01)&&
     Math.abs(dot(saved.right,saved.up)/(norm(saved.right)*norm(saved.up)))<=.88){
   this.right=[...saved.right];this.up=[...saved.up];this.gravity=[...saved.gravity];
  }
 }
 get edges(){return this.right&&this.up&&this.gravity?{right:this.right,up:this.up,gravity:this.gravity}:null;}
 relative(q){return rotation(multiply(inverse(this.center),q));}
 setCenter(q,gravity=null){this.center=[...q];this.right=this.up=null;this.gravity=gravity?unit(rotate(inverse(q),gravity)):null;}
 // A new center for saved edges. False when the case is held differently, and the edges need aiming again.
 // A connection that points by itself asks to keep them; Recalibrate is there if the aim is off.
 recenter(q,gravity,keep=false){
  const held=unit(rotate(inverse(q),gravity)),kept=this.edges&&(keep||dot(held,this.gravity)>=Math.cos(35*Math.PI/180));
  this.center=[...q];if(!kept){this.right=this.up=null;this.gravity=held;}
  return !!kept;
 }
 setAxis(name,q){
  if(!this.center)throw Error('Set the center first.');
  const axis=this.relative(q),degrees=norm(axis)*180/Math.PI;
  if(degrees<5||degrees>80)throw Error('Aim about 10–30° away from center, then try again.');
  const other=name==='right'?this.up:this.right;
  if(other&&Math.abs(dot(axis,other)/(norm(axis)*norm(other)))>.88)
   throw Error('Aim in a different direction. Return to center, then aim toward the top.');
  this[name]=axis;
 }
 point(q,g=null,plane='upright'){
  if(!this.center||!this.right||!this.up)return null;
  let v;
  if(plane==='flatTilt'&&Array.isArray(g)&&g.length===3&&norm(g)>.5){
   v=cross(unit(g),this.gravity||[0,0,1]);
  }else{
   v=this.relative(q);
  }
  const r=this.right,u=this.up,rr=dot(r,r),uu=dot(u,u),ru=dot(r,u),d=rr*uu-ru*ru;
  const x=(dot(v,r)*uu-dot(v,u)*ru)/d,y=(dot(v,u)*rr-dot(v,r)*ru)/d;
  return [Math.max(0,Math.min(1,.5+x/2)),Math.max(0,Math.min(1,.5-y/2))];
 }
}
