;/* fn-docker-desk asset injection v__VERSION__ */
(function(){
  if(window.__fnDockerDeskLoaded)return; window.__fnDockerDeskLoaded=true;
  var MARK='data-fndesk-icon';
  var EMBED=[];
  var TARGET_CACHE=null;
  var TARGET_CACHE_TS=0;
  var OBS_THROTTLE_TS=0;
  var RENDER_START=0;

  function dataIcon(title){var ch=String(title||'D').trim().charAt(0).toUpperCase()||'D';return 'data:image/svg+xml;charset=utf-8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#1677ff"/><stop offset="100%" stop-color="#13c2c2"/></linearGradient></defs><rect width="256" height="256" rx="48" fill="url(#g)"/><text x="128" y="132" font-family="Arial,sans-serif" font-size="104" font-weight="700" fill="#fff" text-anchor="middle" dominant-baseline="middle">'+ch+'</text></svg>');}

  function abortableFetch(url, opts, timeoutMs){
    var ctrl='AbortController' in window?new AbortController():null;
    var merged=opts||{};
    if(ctrl){merged.signal=ctrl.signal;}
    var req=fetch(url,merged);
    if(ctrl && timeoutMs>0){
      setTimeout(function(){try{ctrl.abort();}catch(e){}},timeoutMs);
    }
    return req;
  }

  function loadIcons(){
    var p1=abortableFetch('/userimg/fn-docker-desk.json?t='+Date.now(),{cache:'no-store'},8000)
      .then(function(r){if(!r.ok)throw new Error('local '+r.status);return r.json();})
      .catch(function(){
        return abortableFetch(location.protocol+'//'+location.hostname+':5558/api/icons?t='+Date.now(),{cache:'no-store'},8000)
          .then(function(r){if(!r.ok)throw new Error('api '+r.status);return r.json();})
          .then(function(d){return d.list||d;});
      })
      .catch(function(){return EMBED;})
      .then(function(data){
        if(Array.isArray(data)){data=data.filter(function(it){return it&&it['类型']!=='manager'&&it['标题']!=='飞牛桌面图标';});}
        return data;
      });
    return p1;
  }

  function findTarget(){
    var now=Date.now();
    if(TARGET_CACHE && (now-TARGET_CACHE_TS)<5000 && document.body && document.body.contains(TARGET_CACHE)){
      return TARGET_CACHE;
    }
    var sels=['.box-border.flex.size-full.flex-col.flex-wrap.place-content-start.items-start.py-base-loose','.relative.box-border.h-full.pl-\\[66px\\] .flex.flex-col.flex-wrap','.desktop .box-border.flex.flex-col.flex-wrap','.trim-ui__app-layout--window .box-border.flex.flex-wrap'];
    for(var i=0;i<sels.length;i++){try{var a=document.querySelectorAll(sels[i]); if(a&&a.length){TARGET_CACHE=a[a.length-1];TARGET_CACHE_TS=now;return TARGET_CACHE;}}catch(e){}}
    TARGET_CACHE_TS=now;
    return null;
  }

  function esc(x){return String(x==null?'':x).replace(/[&<>"']/g,function(c){return({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c];});}

  function normalizeImg(item){
    var img=item['图片URL']||'';
    if(!img)return dataIcon(item['标题']||item.title||'D');
    if(img.indexOf('icons/')===0)return location.protocol+'//'+location.hostname+':5558/'+img;
    if(img.indexOf('userimg/')===0||img.indexOf('/userimg/')===0)return '/'+img.replace(/^\/+/,'');
    return img;
  }

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
    var cover=document.createElement('a');
    cover.href=item['跳转URL']||item.url||'#';
    cover.target='_blank';
    cover.rel='noopener';
    cover.style.cssText='position:absolute;inset:0;z-index:5;';
    d.appendChild(cover);
    return d;
  }

  var rendering=false;
  var lastSig='';
  var observer=null;

  function clearAll(){
    var t=findTarget(); if(!t)return;
    var els=t.querySelectorAll('['+MARK+']');
    for(var i=0;i<els.length;i++){try{els[i].remove();}catch(e){}}
    lastSig='';
    window.__fnDeskDiag={ok:true,cleared:els.length,ts:Date.now()};
  }
  function dataSig(data){
    return data.map(function(it){return (it['序号']||0)+'|'+(it['标题']||'')+'|'+(it['跳转URL']||'')+'|'+(it['图片URL']||'');}).join(';;');
  }

  function render(){
    if(location.pathname.indexOf('/login')===0)return;
    if(rendering)return;
    RENDER_START=Date.now();
    rendering=true;
    var safety=setTimeout(function(){if(rendering){rendering=false;}},6000);
    loadIcons().then(function(data){
      if(!Array.isArray(data)){rendering=false;return;}
      if(!data.length){rendering=false;clearAll();return;}
      data.sort(function(a,b){return(a['序号']||0)-(b['序号']||0);});
      var sig=dataSig(data);
      var t=findTarget(); if(!t){rendering=false;return;}
      var existing={};
      var oldEls=t.querySelectorAll('['+MARK+']');
      for(var i=0;i<oldEls.length;i++){
        existing[oldEls[i].getAttribute('data-desktop-item-id')]=oldEls[i];
      }
      if(sig===lastSig && Object.keys(existing).length===data.length){
        rendering=false;
        return;
      }
      if(observer){try{observer.disconnect();}catch(e){}}
      var needed={};
      var frag=document.createDocumentFragment();
      var hasNew=false;
      data.forEach(function(item){
        var seq=item['序号']||0;
        var id='fndesk-'+seq;
        needed[id]=true;
        if(!existing[id]){
          frag.appendChild(buildItem(item,seq));
          hasNew=true;
        }
      });
      for(var id in existing){
        if(!needed[id]){existing[id].remove();}
      }
      if(hasNew){t.appendChild(frag);}
      var sigChanged=sig!==lastSig;
      lastSig=sig;
      if(observer){try{observer.observe(document.getElementById('root')||document.body,{childList:true,subtree:true});}catch(e){}}
      window.__fnDeskDiag={ok:true,count:data.length,existing:Object.keys(existing).length,new:hasNew,sigChanged:sigChanged,ts:Date.now(),elapsedMs:(Date.now()-RENDER_START)};
    }).catch(function(e){try{console.error('fn-docker-desk:',e);}catch(_){} window.__fnDeskDiag={ok:false,err:String(e),ts:Date.now()};})
      .finally(function(){rendering=false;try{clearTimeout(safety);}catch(_){}});
  }

  var timer=null;
  function schedule(){
    clearTimeout(timer);
    timer=setTimeout(render,800);
  }

  function start(){
    try{
      observer=new MutationObserver(function(mutations){
        var skip=true;
        for(var i=0;i<mutations.length;i++){
          var m=mutations[i];
          var added=(m&&m.addedNodes&&m.addedNodes.length)||0;
          var removed=(m&&m.removedNodes&&m.removedNodes.length)||0;
          if(added+removed>5){skip=false;break;}
          var tgt=m.target;
          if(tgt&&tgt.nodeType===1){
            var el=tgt;
            if(el.getAttribute&&el.getAttribute(MARK)){continue;}
            if(el.closest&&el.closest('['+MARK+']')){continue;}
          }
          skip=false;break;
        }
        if(skip)return;
        var now=Date.now();
        if(now-OBS_THROTTLE_TS<2000){return;}
        OBS_THROTTLE_TS=now;
        schedule();
      });
      var root=document.getElementById('root')||document.body;
      if(root){try{observer.observe(root,{childList:true,subtree:true});}catch(e){}}
    }catch(e){}
    schedule();
    setInterval(render,60000);
  }

  // 暴露调试命令（用户在 F12 调用 window.__fnDeskRender() 手动触发一次渲染）
  window.__fnDeskRender=function(){clearTimeout(timer);render();};
  window.__fnDeskClear=clearAll;
  window.__fnDeskDiag={ok:true,phase:'init',ver:'__VERSION__',ts:Date.now()};

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start); else start();
})();
