




local color={
    white_underline=function(s)
    return"\27[1;4m"..s.."\27[0m"
    end,
    
    green=function(s)
    return"\27[32;1m"..s.."\27[0m"
    end,
    
    red=function(s)
    return"\27[31;1m"..s.."\27[0m"
    end,
    
    yellow=function(s)
    return"\27[33;1m"..s.."\27[0m"
    end,
    
    red_highlight=function(s)
    return"\27[41;1;30m"..s.."\27[0m"
    end,
    
    green_highlight=function(s)
    return"\27[42;1;30m"..s.."\27[0m"
    end,
    
    gray=function(s)
    return"\27[31;1;30m"..s.."\27[0m"
    end
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    local PASS,FAIL,NONE,ERROR=1,2,3,4
    
    local test
    local tests={}
    
    local function output_test_result(test)
    print(color.white_underline(test.name))
    
    for _,case in test.cases do
    local msg=({
    [PASS]=color.green"PASS",
    [FAIL]=color.red(case.line and"FAIL:"..case.line or"FAIL"),
    [NONE]=color.yellow"NONE",
    [ERROR]=color.red_highlight"ERROR"
    })[case.result]
    
    print(string.format("[%s] %s",msg,case.name))
    end
    
    print(test.error and color.gray(test.error)or"")
    end
    
    local function CASE(name)
    assert(test,"no active test")
    
    local case={
    name=name,
    result=NONE
    }
    
    test.case=case
    table.insert(test.cases,case)
    end
    
    local function CHECK(value,stack)
    assert(test,"no active test")
    local case=test.case
    
    if not case then
    CASE""
    case=test.case
    end
    
    assert(case,"no active case")
    
    if case.result~=FAIL then
    case.result=value and PASS or FAIL
    case.line=debug.info(stack and stack+1 or 2,"l")
    end
    
    return value
    end
    
    local function TEST(name,fn)
    local active=test
    assert(not active,"cannot start test while another test is in progress")
    
    test={
    name=name,
    cases={},
    duration=0
    };assert(test)
    
    table.insert(tests,test)
    
    local start=os.clock()
    local err_msg
    local success=xpcall(fn,function(m)err_msg=m..debug.traceback("",2)end)
    test.duration=os.clock()-start
    
    if not test.case then CASE""end
    assert(test.case,"no active case")
    
    if not success then
    test.case.result=ERROR
    test.error=err_msg
    end
    
    test=nil
    end
    
    local function FINISH()
    local success=true
    local total_cases=0
    local passed_cases=0
    local duration=0
    
    for _,test in tests do
    duration=    duration+test.duration
    for _,case in test.cases do
    total_cases=    total_cases+1
    if case.result==PASS or case.result==NONE then
    passed_cases=    passed_cases+1
    else
    success=false
    end
    end
    
    output_test_result(test)
    end
    
    print(string.format(
    "%d/%d test cases passed in %.3f ms.",
    passed_cases,
    total_cases,
    duration*1e3
    ))
    
    local fails=total_cases-passed_cases
    
    print(
    (
    fails>0
    and color.red_highlight
    or color.green_highlight
    )(string.format("%d, %s",fails,fails==1 and"fail"or"fails"))
    )
    
    return success,table.clear(tests)
    end
    
    
    
    
    
    
    
    
    
    
    
    local bench
    
    function START(iter)
    local n=iter or 1
    assert(n>0,"iterations must be greater than 0")
    assert(bench,"no active benchmark")
    assert(not bench.time_start,"clock was already started")
    
    bench.iterations=n
    bench.memory_start=gcinfo()
    bench.time_start=os.clock()
    return n
    end
    
    local function BENCH(name,fn)
    local active=bench
    assert(not active,"a benchmark is already in progress")
    
    bench={};assert(bench)
    
    ;(collectgarbage)"collect"
    
    local mem_start=gcinfo()
    local time_start=os.clock()
    local err_msg
    
    local success=xpcall(fn,function(m)
    err_msg=m..debug.traceback("",2)
    end)
    
    local time_stop=os.clock()
    local mem_stop=gcinfo()
    
    if not success then
    print("["..color.red_highlight"ERROR".."] "..name)
    print(color.gray(err_msg))
    else
    time_start=bench.time_start or time_start
    mem_start=bench.memory_start or mem_start
    
    local n=bench.iterations or 1
    local duration=time_stop-time_start
    local allocated=mem_stop-mem_start
    
    print(string.format(
    "[ %.3f us | %4.0f B ] %s",
    duration/n*1e6,
    allocated/n*1e3,
    name
    ))
    end
    
    bench=nil
    end
    
    
    
    
    
    local function print2(v)
    
    
    
    local function tos(value,stack,str)
    local TAB="    "
    local indent=table.concat(table.create(stack,TAB))
    
    if type(value)=="string"then
    local n=str.n
    str[n+1]="\""
    str[n+2]=value
    str[n+3]="\""
    str.n=n+3
    elseif type(value)~="table"then
    local n=str.n
    str[n+1]=value==nil and"nil"or tostring(value)
    str.n=n+1
    elseif next(value)==nil then
    local n=str.n
    str[n+1]="{}"
    str.n=n+1
    else
    local tabbed_indent=indent..TAB
    
    str.n=    str.n+1
    str[str.n]="{\n"
    
    local i,v=next(value,nil)
    while v~=nil do
    local n=str.n
    str[n+1]=tabbed_indent
    
    if type(i)~="string"then
    str[n+2]="["
    str[n+3]=tostring(i)
    str[n+4]="]"
    n=    n+4
    else
    str[n+2]=tostring(i)
    n=    n+2
    end
    
    str[n+1]=" = "
    str.n=n+1
    
    tos(v,stack+1,str)
    
    i,v=next(value,i)
    
    n=str.n
    str[n+1]=v~=nil and",\n"or"\n"
    str.n=n+1
    end
    
    local n=str.n
    str[n+1]=indent
    str[n+2]="}"
    str.n=n+2
    end
    end
    
    local str={n=0}
    tos(v,0,str)
    print(table.concat(str))
    end
    
    
    
    
    
    local function shallow_eq(a,b)
    if#a~=#b then return false end
    
    for i,v in next,a do
    if b[i]~=v then
    return false
    end
    end
    
    for i,v in next,b do
    if a[i]~=v then
    return false
    end
    end
    
    return true
    end
    
    local function deep_eq(a,b)
    if#a~=#b then return false end
    
    for i,v in next,a do
    if type(b[i])=="table"and type(v)=="table"then
    if deep_eq(b[i],v)==false then return false end
    elseif b[i]~=v then
    return false
    end
    end
    
    for i,v in next,b do
    if type(a[i])=="table"and type(v)=="table"then
    if deep_eq(a[i],v)==false then return false end
    elseif a[i]~=v then
    return false
    end
    end
    
    return true
    end
    
    
    
    
    
    return{
    test=function()
    return TEST,CASE,CHECK,FINISH
    end,
    
    benchmark=function()
    return BENCH,START
    end,
    
    print2=print2,
    
    seq=shallow_eq,
    deq=deep_eq
    }