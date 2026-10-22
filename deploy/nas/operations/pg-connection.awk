# Parse the supported PostgreSQL URI without placing it/password in argv.
# Runs inside the official client image; writes to its private tmpfs only.
function reject() { exit 1 }
function decode(s,    i,c,h,n,r) {
    r=""
    for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (c=="%") {
            h=toupper(substr(s,i+1,2))
            if (length(h)!=2 || h !~ /^[0-9A-F][0-9A-F]$/) reject()
            n=(index("0123456789ABCDEF",substr(h,1,1))-1)*16+index("0123456789ABCDEF",substr(h,2,1))-1
            if (n==0 || n==10 || n==13) reject()
            c=sprintf("%c",n); i+=2
        }
        if (c ~ /[\r\n]/) reject()
        r=r c
    }
    return r
}
function pgpass(s,    i,c,r) {
    r=""
    for(i=1;i<=length(s);i++) { c=substr(s,i,1); if(c==":" || c=="\\") r=r "\\"; r=r c }
    return r
}
BEGIN {
    uri=ENVIRON["DATABASE_URL"]
    if(uri !~ /^postgres(ql)?:\/\//) reject()
    sub(/^postgres(ql)?:\/\//,"",uri)
    pos=index(uri,"@"); if(!pos) reject()
    auth=substr(uri,1,pos-1); uri=substr(uri,pos+1)
    if(index(uri,"@")) reject()
    pos=index(auth,":"); if(!pos) reject()
    user=decode(substr(auth,1,pos-1)); password=decode(substr(auth,pos+1))
    pos=index(uri,"/"); if(!pos) reject()
    authority=substr(uri,1,pos-1); uri=substr(uri,pos+1)
    if(substr(authority,1,1)=="[") {
        pos=index(authority,"]"); if(!pos) reject()
        host=substr(authority,2,pos-2); rest=substr(authority,pos+1)
        if(host !~ /^[0-9A-Fa-f:.]+$/) reject()
        if(rest!="" && rest !~ /^:[0-9]+$/) reject()
        port=(rest=="" ? "5432" : substr(rest,2))
    } else {
        n=split(authority,a,":"); if(n>2) reject()
        host=a[1]; port=(n==1 ? "5432" : a[2])
        if(host !~ /^[A-Za-z0-9_.-]+$/) reject()
    }
    if(port !~ /^[0-9]+$/ || port+0<1 || port+0>65535) reject()
    pos=index(uri,"?"); params=""
    if(pos) { params=substr(uri,pos+1); uri=substr(uri,1,pos-1) }
    database=decode(uri)
    if(database!=ENVIRON["MOMO_EXPECTED_DATABASE"] || user!=ENVIRON["MOMO_EXPECTED_ROLE"]) reject()
    if(password=="" || database !~ /^[A-Za-z0-9_]+$/ || user !~ /^[A-Za-z0-9_]+$/) reject()
    sslmode="prefer"; timeout=10; seen_ssl=0; seen_timeout=0
    n=split(params,p,"&")
    for(i=1;i<=n;i++) {
        if(p[i]=="") continue
        pos=index(p[i],"="); if(!pos) reject()
        key=decode(substr(p[i],1,pos-1)); value=decode(substr(p[i],pos+1))
        if(key=="sslmode") {
            if(seen_ssl++ || value !~ /^(disable|allow|prefer|require|verify-ca|verify-full)$/) reject()
            sslmode=value
        } else if(key=="connect_timeout") {
            if(seen_timeout++ || value !~ /^[0-9]+$/ || value+0<1 || value+0>30) reject()
            timeout=value
        } else reject()
    }
    print "[momobox]\nhost=" host "\nport=" port "\ndbname=" database "\nuser=" user "\nsslmode=" sslmode "\nconnect_timeout=" timeout "\napplication_name=momobox-operations" > "/tmp/momo-service.conf"
    print pgpass(host) ":" pgpass(port) ":" pgpass(database) ":" pgpass(user) ":" pgpass(password) > "/tmp/momo.pgpass"
}
