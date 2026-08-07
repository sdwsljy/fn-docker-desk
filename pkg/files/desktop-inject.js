;/* fn-docker-desk asset injection v__VERSION__ */
(function(){
  if(window.__fnDockerDeskLoaded)return; window.__fnDockerDeskLoaded=true;
  var MARK='data-fndesk-icon';
  var EMBED=[];
  function dataIcon(title){var ch=String(title||'D').trim().charAt(0).toUpperCase()||'D';return 'data:image/svg+xml;charset=utf-8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#1677ff"/><stop offset="100%" stop-color="#13c2c2"/></linearGradient></defs><rect width="256" height="256" rx="48" fill="url(#g)"/><text x="128" y="132" font-family="Arial,sans-serif" font-size="104" font-weight="700" fill="#fff" text-anchor="middle" dominant-baseline="middle">'+ch+'</text></svg>');}
  function loadIcons(){
    return fetch('/userimg/fn-docker-desk.json?t='+Date.now(),{cache:'no-store'}).then(function(r){if(!r.ok)throw new Error('local '+r.status);return r.json();})
      .catch(function(){return fetch(location.protocol+'//'+location.hostname+':5558/api/icons?t='+Date.now(),{cache:'no-store'}).then(function(r){if(!r.ok)throw new Error('api '+r.status);return r.json();}).then(function(d){return d.list||d;});})
      .catch(function(){return EMBED;}).then(function(data){
        // 过滤管理面板自身图标（由 fnOS 应用中心管理，避免重复/重复管理）
        if(Array.isArray(data)){data=data.filter(function(it){return it&&it['类型']!=='manager'&&it['标题']!=='飞牛桌面图标';});}
        return data;
      });
  }
  function findTarget(){
    var sels=['.box-border.flex.size-full.flex-col.flex-wrap.place-content-start.items-start.py-base-loose','.relative.box-border.h-full.pl-\\[66px\\] .flex.flex-col.flex-wrap','.desktop .box-border.flex.flex-col.flex-wrap','.trim-ui__app-layout--window .box-border.flex.flex-wrap'];
    for(var i=0;i<sels.length;i++){try{var a=document.querySelectorAll(sels[i]); if(a&&a.length)return a[a.length-1];}catch(e){}}
    var all=document.querySelectorAll('div'), best=null, score=0;
    for(var j=0;j<all.length;j++){var el=all[j], cls=String(el.className||''), s=0; if(cls.indexOf('login-form')>=0)continue; if(cls.indexOf('flex')>=0)s++; if(cls.indexOf('wrap')>=0)s+=2; if(cls.indexOf('size-full')>=0||cls.indexOf('h-full')>=0)s++; try{var cs=getComputedStyle(el); if(cs.display.indexOf('flex')>=0)s++; if(cs.flexWrap==='wrap')s+=2;}catch(e){} for(var k=0;k<el.children.length;k++){var c=el.children[k]; if(c.tagName==='A'&&(c.querySelector('img')||c.querySelector('svg')))s+=3; if(c.getAttribute&&(c.getAttribute('data-desktop-item-id')||c.getAttribute('data-testid')))s+=3;} if(s>score){best=el;score=s;}}
    return score>=3?best:null;
  }
  function esc(x){return String(x==null?'':x).replace(/[&<>"']/g,function(c){return({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c];});}
  function normalizeImg(item){
    var img=item['图片URL']||'';
    if(!img)return dataIcon(item['标题']||item.title||'D');
    if(img.indexOf('icons/')===0)return location.protocol+'//'+location.hostname+':5558/'+img;
    if(img.indexOf('userimg/')===0||img.indexOf('/userimg/')===0)return '/'+img.replace(/^\/+/,'');
    return img;
  }
  // 完全复刻 fnOS 原生桌面图标结构（源码：div h-[120px] w-[144px] pt-[22px]，图标 52px，标题 14px/18px）
  // 保证尺寸、边距、对齐与系统图标完全一致
  function buildItem(item,seq){
    var d=document.createElement('div');
    d.setAttribute(MARK,'1');
    d.setAttribute('data-desktop-item-id','fndesk-'+seq);
    d.className='box-border flex h-[120px] w-[144px] cursor-default select-none flex-col items-center gap-[10px] rounded-xl pt-[22px]';
    d.title=item['标题']||'';
    d.style.position='relative';
    var inner=document.createElement('div');
    inner.className='inline-flex cursor-pointer flex-col items-center gap-[10px]';
    inner.setAttribute('data-desktop-item-context-hotspot','true');
    var iconBox=document.createElement('div');
    iconBox.className='relative flex size-[52px] shrink-0 flex-row items-center justify-center transition-all duration-150';
    var iconWrap=document.createElement('div');
    iconWrap.className='absolute inset-0 overflow-hidden';
    var img=document.createElement('img');
    img.className='!h-[52px] !w-[52px] !p-0';
    img.src=normalizeImg(item);
    img.alt=item['标题']||'';
    img.onerror=function(){this.onerror=null;this.src=dataIcon(item['标题']||item.title||'D');};
    iconWrap.appendChild(img);
    iconBox.appendChild(iconWrap);
    var tWrap=document.createElement('div');
    tWrap.className='flex min-h-base w-fit max-w-[128px] shrink-0 items-start justify-center';
    var tDiv=document.createElement('div');
    tDiv.className='line-clamp-2 max-w-[128px] break-words shrink-0 text-center align-top text-[14px] font-bold leading-[18px] text-white';
    tDiv.textContent=item['标题']||'';
    tWrap.appendChild(tDiv);
    inner.appendChild(iconBox);
    inner.appendChild(tWrap);
    d.appendChild(inner);
    // 透明 <a> 覆盖层：浏览器原生导航打开链接，避免 window.open 被弹窗拦截导致点击无反应
    var cover=document.createElement('a');
    cover.href=item['跳转URL']||item.url||'#';
    cover.target='_blank';
    cover.rel='noopener';
    cover.style.cssText='position:absolute;inset:0;z-index:5;';
    d.appendChild(cover);
    return d;
  }
  function render(){
    if(location.pathname.indexOf('/login')===0)return;
    loadIcons().then(function(data){
      if(!Array.isArray(data)||!data.length)return;
      var t=findTarget(); if(!t){console.warn('fn-docker-desk: desktop container not found'); return;}
      var old=t.querySelectorAll('['+MARK+']'); for(var i=0;i<old.length;i++)old[i].remove();
      data.sort(function(a,b){return(a['序号']||0)-(b['序号']||0);});
      data.forEach(function(item,idx){
        t.appendChild(buildItem(item,idx));
      });
      window.__fnDeskDiag={ok:true,count:data.length,targetClass:String(t.className||''),ts:Date.now()};
    }).catch(function(e){console.error('fn-docker-desk:',e); window.__fnDeskDiag={ok:false,err:String(e),ts:Date.now()};});
  }
  var timer=null; function schedule(){clearTimeout(timer); timer=setTimeout(render,250);}
  function start(){try{new MutationObserver(schedule).observe(document.getElementById('root')||document.body,{childList:true,subtree:true});}catch(e){} schedule(); var n=0;(function wait(){render(); if(++n<180)setTimeout(wait,1000);})();}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start); else start();
})();
