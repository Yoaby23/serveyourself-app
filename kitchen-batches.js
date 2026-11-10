/* Neighboring tickets can share preparation without merging accounts or changing queue priority. */
(() => {
    const windowMs=5*60000;
    function itemsFor(ticket,stationKey='all',products=[]) {
        return (ticket.items||[]).filter(i=>stationKey==='all'||String(i.station_id||products.find(p=>p.id===i.id)?.kitchen_station_id||'general')===stationKey);
    }
    function itemKey(i,products) {return String(i.id).toLowerCase()+'@'+String(i.station_id||products.find(p=>p.id===i.id)?.kitchen_station_id||'general');}
    function stateFor(ticket,stationKey) {return stationKey==='all'?ticket.status:ticket.kitchen_ticket_station_statuses?.find(s=>s.station_key===stationKey)?.status;}
    function build(list,{stationKey='all',products=[],now=Date.now()}={}) {
        const groups=[];
        function eligible(t) {
            const items=itemsFor(t,stationKey,products),state=stateFor(t,stationKey);
            return ['pendiente','preparando'].includes(state)&&Number(t.priority_override||0)>=0&&!String(t.notes||'').trim()&&items.length>0&&items.every(i=>i.id&&Number(i.qty)>0)&&(t.items||[]).every(i=>['notes','note','modifiers','options','instructions'].every(k=>i[k]==null||i[k]===''||JSON.stringify(i[k])==='[]'||JSON.stringify(i[k])==='{}'))&&Number.isFinite(Date.parse(t.target_ready_at))&&Number.isFinite(Date.parse(t.recommended_start_at))&&Date.parse(t.recommended_start_at)<=now+windowMs;
        }
        for(let i=0;i<list.length;) {
            const first=list[i],tickets=[first];let common=new Set(itemsFor(first,stationKey,products).map(x=>itemKey(x,products)));
            let minTarget=Date.parse(first.target_ready_at),maxTarget=minTarget,minStart=Date.parse(first.recommended_start_at),maxStart=minStart;
            if(eligible(first))while(i+tickets.length<list.length&&tickets.length<5) {
                const next=list[i+tickets.length];
                if(!eligible(next)||stateFor(next,stationKey)!==stateFor(first,stationKey)||Number(next.priority_override||0)!==Number(first.priority_override||0))break;
                const keys=new Set(itemsFor(next,stationKey,products).map(x=>itemKey(x,products))),intersection=new Set([...common].filter(k=>keys.has(k)));
                const target=Date.parse(next.target_ready_at),start=Date.parse(next.recommended_start_at);
                if(!intersection.size||Math.max(maxTarget,target)-Math.min(minTarget,target)>windowMs||Math.max(maxStart,start)-Math.min(minStart,start)>windowMs)break;
                tickets.push(next);common=intersection;minTarget=Math.min(minTarget,target);maxTarget=Math.max(maxTarget,target);minStart=Math.min(minStart,start);maxStart=Math.max(maxStart,start);
            }
            const totals=new Map();
            if(tickets.length>1)for(const t of tickets)for(const item of itemsFor(t,stationKey,products)) {
                const key=itemKey(item,products);if(!common.has(key))continue;
                const total=totals.get(key)||{name:item.nombre||products.find(p=>p.id===item.id)?.name||'Producto',qty:0,allocations:[]};
                total.qty+=Number(item.qty);total.allocations.push({ticketId:t.id,qty:Number(item.qty)});totals.set(key,total);
            }
            groups.push({tickets,startIndex:i,commonItems:[...totals.values()],state:stateFor(first,stationKey)});i+=tickets.length;
        }
        return groups;
    }
    window.SYKitchenBatches={build,itemsFor};
})();
