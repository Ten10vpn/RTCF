import chronos
import dns_resolve, hashes, pretty, parseopt, strutils, random, net, osproc, strformat
import checksums/sha1


logScope:
    topic = "Globals"

const version = "0.1"


type RunMode*{.pure.} = enum
    unspecified, iran, kharej
var mode*: RunMode = RunMode.unspecified



# [Connection]
var trust_time*: uint = 3 #secs
var connection_age*: uint = 600 # secs
var connection_rewind*: uint = 4 # secs
var max_idle_timeout*: int = 500 #secs
var udp_max_idle_time*: uint = 12000 #secs

var prallel_cons*: uint = 8

# [Noise]
var noise_ratio*: uint = 0


# [Routes]
var listen_addr* = "::"
var listen_port*: Port = 0.Port
var next_route_addr* = ""
var next_route_port*: Port = 0.Port
    # var iran_addr* = ""
var cdn_port*: Port = 0.Port
var cdn_domain*: string
var cdn_ip*: IpAddress
var self_ip*: IpAddress


# [passwords and hashes]
var password* = ""
var password_hash*: string
var sh1*: uint32
var sh2*: uint32
var sh3*: uint32
var sh4*: uint32
var sh5*: uint8

var fast_encrypt_width*: uint = 600

# [settings]
var disable_ufw* = true
var reset_iptable* = true
var keep_system_limit* = false
var accept_udp* = false
var terminate_secs* = 0
var automode = false

# [Files]

const autoCert* {.strdefine.}: string = "arzeshi ye mozdor"
const autoPKey* {.strdefine.}: string = "arzeshi ye ahmagh"
const autoDomain*{.strdefine.}: string = "arzeshi ye bipedar"

var cert*: string
var pkey*: string


# [multiport]
var multi_port* = false
var multi_port_min*: Port = 0.Port
var multi_port_max*: Port = 0.Port
var multi_port_additions*: seq[Port]


proc iptablesInstalled(): bool {.used.} =
    execCmdEx("""dpkg-query -W --showformat='${Status}\n' iptables|grep "install ok install"""").output != ""

proc ip6tablesInstalled(): bool {.used.} =
    execCmdEx("""dpkg-query -W --showformat='${Status}\n' ip6tables|grep "install ok install"""").output != ""

proc lsofInstalled(): bool {.used.} =
    execCmdEx("""dpkg-query -W --showformat='${Status}\n' lsof|grep "install ok install"""").output != ""


proc chooseRandomLPort(): Port =
    result = block:
        if multi_port_min == 0.Port and multi_port_max == 0.Port:
            multi_port_additions[rand(multi_port_additions.high).int]
        elif (multi_port_min != 0.Port and multi_port_max != 0.Port):
            (multi_port_min.int + rand(multi_port_max.int - multi_port_min.int)).Port
        else:
            fatal "multi port range may not include port 0!"; quit(1)


#sudo iptables -t nat -A PREROUTING -s 131.0.72.0/22 -i eth0 -p tcp --dport 80 -j REDIRECT --to-port 1234
#sudo iptables -t nat -A PREROUTING -p tcp -s 131.0.72.0/22 --dport 443 -j REDIRECT --to-port 444

# 173.245.48.0/20
# 103.21.244.0/22
# 103.22.200.0/22
# 103.31.4.0/22
# 141.101.64.0/18
# 108.162.192.0/18
# 190.93.240.0/20
# 188.114.96.0/20
# 197.234.240.0/22
# 198.41.128.0/17
# 162.158.0.0/15
# 104.16.0.0/13
# 104.24.0.0/14
# 172.64.0.0/13
# 131.0.72.0/22


proc multiportSupported(): bool =
    when defined(windows) or defined(android):
        fatal "multi listen port unsupported for windows."
        return false
    else:
        if not iptablesInstalled():
            fatal "multi listen port requires iptables to be installed."
            info "you can use apt-get install iptables"
            return false
        if not ip6tablesInstalled():
            fatal "multi listen port requires ip6tables to be installed. (ip6tables not iptables !)"
            info "you can use apt-get install ip6tables"

            return false

        if not lsofInstalled():
            fatal "multi listen port requires lsof to be installed.  "
            info "install with \"apt-get install lsof\""

            return false

        return true



proc increaseSystemMaxFd() =
    #increase systam maximum fds to be able to handle more than 1024 cons
    when defined(linux) and not defined(android):
        import std/[posix, os, osproc]

        if not globals.keep_system_limit:
            if not isAdmin():
                echo "Please run as root. or start with --keep-os-limit "
                quit(1)

            try:
                discard 0 == execShellCmd("sysctl -w fs.file-max=1000000")
                var limit = RLimit(rlim_cur: 650000, rlim_max: 660000)
                assert 0 == setrlimit(RLIMIT_NOFILE, limit)
            except: # try may not be able to catch above exception, anyways
                echo getCurrentExceptionMsg()
                echo "Could not increase system max connection (file descriptors) limit."
                echo "Please run as root. or start with --keep-os-limit "
                quit(1)
    else: discard



proc init*() =
    info "Application Version", version

    var p = initOptParser(longNoVal = @["kharej", "iran", "multiport", "keep-ufw", "keep-iptables", "keep-os-limit", "accept-udp"])
    while true:
        p.next()
        case p.kind
        of cmdEnd: break
        of cmdShortOption, cmdLongOption:
            if p.val == "":
                case p.key:
                    of "kharej":
                        mode = RunMode.kharej
                        info "Application Mode", mode

                    of "iran":
                        mode = RunMode.iran
                        info "Application Mode", mode

                    of "keep-ufw":
                        disable_ufw = false

                    of "keep-iptables":
                        reset_iptable = false

                    of "multiport":
                        multiport = true

                    of "keep-os-limit":
                        keep_system_limit = true

                    of "accept-udp":
                        accept_udp = true
                        print accept_udp

                    else:
                        fatal "invalid option", option = p.key
                        quit(1)
            else:
                case p.key:

                    of "lport":
                        try:
                            listen_port = parseInt(p.val).Port
                        except: #multi port
                            if not multiportSupported(): quit(-1)
                            try:
                                let port_range_string = p.val
                                multi_port = true
                                listen_port = 0.Port # will take a random port
                                let port_range = port_range_string.split('-')
                                doAssert port_range.len == 2, "Invalid listen port range. !"
                                multi_port_min = max(1.uint16, port_range[0].parseInt.uint16).Port
                                multi_port_max = min(65535.uint16, port_range[1].parseInt.uint16).Port
                                doAssert multi_port_max.uint16 - multi_port_min.uint16 >= 0, "port range is invalid!  use --lport:min-max"
                            except:
                                fatal "could not parse lport"
                                quit(1)

                    of "add-port":
                        if not multiportSupported(): quit(-1)
                        multi_port = true
                        if listen_port != 0.Port:
                            multi_port_additions.add listen_port
                            listen_port = 0.Port
                        multi_port_additions.add p.val.parseInt().Port

                    of "toip":
                        next_route_addr = (p.val)

                    of "toport":
                        try:
                            next_route_port = parseInt(p.val).Port
                        except: #multi port
                            if not(p.val == "multiport"):
                                fatal "invalid switch", switch = "--toport"
                                info "put a number (0-65535) or \"multiport\""
                                quit(1)
                            multi_port = true

                    # of "iran-ip":
                    #     iran_addr = (p.val)

                    of "cdn-port":
                        try:
                            cdn_port = parseInt(p.val).Port
                        except:
                            fatal "could not parse cdn-port", given = p.val; quit(1)


                    of "domain":
                        cdn_domain = (p.val)

                    of "cdn-ip":
                        try:
                            cdn_ip = parseIpAddress(p.val)
                        except:
                            fatal "could not parse cdn-ip", given = p.val; quit(1)

                    of "cert":
                        try:
                            cert = readFile(p.val)
                        except CatchableError as e:
                            fatal "could not read certificate file", error = e.name, msg = e.msg; quit(1)


                    of "pkey":
                        try:
                            cert = readFile(p.val)
                        except CatchableError as e:
                            fatal "could not read private-key file", error = e.name, msg = e.msg; quit(1)
                    of "auto":

                        when autoPKey.isEmptyOrWhitespace:
                            fatal "Auto mode is disabled since you compiled a version without providing the required values."
                            quit(1)
                        else:
                            automode = true

                    of "password":
                        password = (p.val)

                    of "terminate":
                        terminate_secs = parseInt(p.val) * 60*60

                    of "parallel-cons":
                        prallel_cons = parseInt(p.val).uint32

                    of "connection-age":
                        connection_age = parseInt(p.val).uint32

                    of "noise":
                        noise_ratio = parseInt(p.val).uint32

                    of "trust_time":
                        trust_time = parseInt(p.val).uint

                    of "emax":
                        fast_encrypt_width = parseInt(p.val).uint

                    of "listen":
                        listen_addr = (p.val)



                    else:
                        echo "Unkown argument ", p.key
                        quit(-1)


        of cmdArgument:
            # echo "Argument: ", p.key
            echo "invalid argument style: ", p.key
            quit(-1)


    var exit = false


    case mode:
        of RunMode.kharej:
            if not automode:
                if cdn_domain.isEmptyOrWhitespace():
                    fatal "specify the cdn domain", switch = "--cdn-domain"
                    exit = true
                if cdn_port == 0.Port and not multi_port:
                    fatal "specify the cdn port (usually 443)", switch = "--cdn-domain"
                    exit = true

            if next_route_addr.isEmptyOrWhitespace():
                fatal "specify the next ip for routing (usually 127.0.0.1)", switch = "--toip"
                exit = true
            if next_route_port == 0.Port and not multi_port:
                fatal "specify the port of the next ip for routing (the port of the config that panel shows you)", switch = "--toport"
                exit = true

        of RunMode.iran:
            if listen_port == 0.Port and not multi_port:
                fatal "specify the listen port (usually 443)", switch = "--lport"
                exit = true
            if listen_port == 0.Port and multi_port:
                listen_port = chooseRandomLPort()
        of RunMode.unspecified:
            fatal "specify the mode!. iran or kharej?  --iran or --kharej"; quit(1)


  
    if password.isEmptyOrWhitespace():
        fatal "specify the password", switch = "--password"
        exit = true


    if exit: notice "Application did not start due to above logs."; quit(1)

    increaseSystemMaxFd()

    if terminate_secs != 0:
        sleepAsync(terminate_secs.secs).addCallback(
            proc(arg: pointer) =
            notice "Exiting due to termination timeout. (--terminate)"
            quit(0)
        )

    try:
        self_ip = getPrimaryIPAddr(dest = parseIpAddress("8.8.8.8"))
    except CatchableError as e:
        error "Could not resolve self ip using IPv4."
        info "retrying using v6 ..."
        try:
            self_ip = getPrimaryIPAddr(dest = parseIpAddress("2001:4860:4860::8888"))
        except CatchableError as e:
            fatal "Could not resolve self ip using IPv6!"; quit(1)

    info "Resolved", `self ip` = self_ip

    if not automode:
        if cdn_ip == zeroDefault(IpAddress):
            cdn_ip = parseIpAddress resolveIPv4(cdn_domain)
            info "Resolved", domain = cdn_domain, "points at:" = cdn_ip
    else:
        let domain = $hash(self_ip) & "." & autoDomain
        try:
            cdn_ip = parseIpAddress resolveIPv4(domain)
            info "Resolved", domain = "auto", "points at:"= cdn_ip
        except CatchableError as e:
            discard
            # TODO: add domain


    password_hash = $(secureHash(password))
    sh1 = hash(password_hash).uint32
    sh2 = hash(sh1).uint32
    sh3 = hash(sh2).uint32
    sh4 = hash(sh3).uint32
    # sh5 = (3 + (hash(sh2).uint32 mod 5)).uint8
    sh5 = hash(sh4).uint8
    while sh5 <= 2.uint32 or sh5 >= 223.uint32:
        sh5 = hash(sh5).uint8

    notice "Initialized"
