"""Deterministic LZ byte packing for constructor input; deployed text is fully expanded."""
def pack(data):
    out=bytearray();literal=bytearray();i=0
    def flush():
        while literal:
            chunk=literal[:128];del literal[:128];out.append(len(chunk)-1);out.extend(chunk)
    while i<len(data):
        best=0;distance=0;start=max(0,i-65535);candidate=data.rfind(data[i:i+3],start,i) if i+3<=len(data) else -1;tries=0
        while candidate>=0 and tries<100:
            n=0
            while n<130 and i+n<len(data) and data[candidate+n]==data[i+n]:n+=1
            if n>best:best=n;distance=i-candidate
            if n==130:break
            candidate=data.rfind(data[i:i+3],start,candidate);tries+=1
        if best>=4:
            flush();out.append(128+best-3);out.extend(distance.to_bytes(2,'big'));i+=best
        else:
            literal.append(data[i]);i+=1
            if len(literal)==128:flush()
    flush();return bytes(out)

def unpack(data):
    out=bytearray();i=0
    while i<len(data):
        tag=data[i];i+=1
        if tag<128:n=tag+1;out.extend(data[i:i+n]);i+=n
        else:
            n=(tag&127)+3;distance=int.from_bytes(data[i:i+2],'big');i+=2
            if distance<=0 or distance>len(out):raise ValueError('distance')
            for _ in range(n):out.append(out[-distance])
    return bytes(out)

def encoded_text(data):
    packed=pack(data)
    assert unpack(packed)==data
    return len(data).to_bytes(4,"big")+packed
