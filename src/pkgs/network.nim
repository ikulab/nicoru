{.deadCodeElim:on.}

import posix, strformat, os, strutils, osproc, json, marshal, options, sequtils
import linuxutils, settings

type
  IpAddr = object
    address: string
    subnetMask: Option[int]

  Veth = object
    name: string
    ipAddr: Option[IpAddr]

  NetworkInterface* = object
    containerId: string
    # Created inside a container
    veth: Option[Veth]
    # Connect a bridge with veth (Doesn't have a IP Address)
    brVeth: Option[Veth]

  Bridge* = object
    # Bridge name
    name*: string
    # Connet to default NIC
    rtVeth: Option[Veth]
    # Connect a bridge with rtVeth (Doesn't have a IP Address)
    brRtVeth: Option[Veth]
    # veths for a container
    ifaces*: seq[NetworkInterface]

  Network* = object
    bridges*: seq[Bridge]
    currentBridgeIndex*: int

proc networkStatePath*(): string {.inline.} =
  return "/var/run/nicoru/network_state.json"

proc lockedNetworkStatePath*(): string {.inline.} =
  return "/var/run/nicoru/network_state.json.lock"

proc baseVethName*(): string {.inline.} =
  return "veth"

proc baseBrVethName*(): string {.inline.} =
  return "brVeth"

proc defaultBridgeName*(): string {.inline.} =
  return "nicoru0"

proc defaultBridgeIpAddr*(): IpAddr {.inline.} =
  return IpAddr(address: "10.0.0.1", subnetMask: some(16))

proc defaultRtBridgeVethName*(): string {.inline.} =
  return "rtVeth0"

proc defaultRtRtBridgeVethName*(): string {.inline.} =
  return "brRtVeth0"

proc defaultNatAddress*(): IpAddr {.inline.} =
  return IpAddr(address: "10.0.0.0", subnetMask: some(24))

proc getAllInterfaceName(): seq[string] =
  let
    cmd = "ip a"
    r = execCmdEx(cmd)

  if r.exitCode != 0:
    exception(fmt"Failed to '{cmd}': exitCode: {r.exitCode}")

  let outputLines = r.output.splitLines
  for outputL in outputLines:
    if outputL.len > 0 and outputL[0].isDigit:
      let
        l = outputL.split(" ")
        interfaceName = l[1]

      if interfaceName.len > 2:
        # Remove ':' from interfaceName
        result.add interfaceName[0 .. interfaceName.high - 1]

proc getActualInterfaceName(interfaceName: string): string =
  if interfaceName.len < 1:
    exception("Invalid interface name")

  let r = execCmdEx("ip a")

  if r.exitCode == 0:
    let lines = r.output.splitLines
    for l in lines:
      if l.contains(interfaceName):
        let splited = l.split(":")

        try: result = splited[1].splitWhitespace[0]
        except: exception(fmt"Failed to get actual interface name. Invalid value: '{splited}'")

proc getDefaultNetworkInterface*(): string =
  let
    cmd = "ip route"
    r = execCmdEx(cmd)

  if r.exitCode != 0 or r.output.len == 0:
    exception(fmt"Failed to '{cmd}': exitCode: {r.exitCode}")

  for l in r.output.split('\n'):
    let splited = l.splitWhitespace
    if splited[0] == "default":
      for index, word in splited:
        if "dev" == word:
          return splited[index + 1]

proc getRtVethIpAddr*(bridge: Bridge): IpAddr {.inline.} =
  return bridge.rtVeth.get.ipAddr.get

proc bridgeExists*(bridgeName: string): bool =
  let
    cmd = "ip a"
    r = execCmdEx(cmd)

  if r.exitCode != 0:
    exception(fmt"Failed to '{cmd}': exitCode: {r.exitCode}")

  let outputLines = r.output.splitLines
  for outputL in outputLines:
    if outputL.len > 0 and outputL[0].isDigit:
      let
        l = outputL.split(" ")
        interfaceName = l[1][0 ..< l[1].high]

      if interfaceName == bridgeName:
        return true

proc getVethIpAddr*(iface: NetworkInterface): IpAddr {.inline.} =
  return iface.veth.get.ipAddr.get

proc getPrimaryIpOfHost(): IpAddr =
  let
    # TODO: This method is not certain. Need fix it.
    cmd = "hostname --ip-address"
    r = execCmdEx(cmd)

  if r.exitCode != 0:
    exception(fmt"Failed to '{cmd}': exitCode: {r.exitCode}")

  let splited = r.output.split(" ")
  return IpAddr(address: splited[0].replace("\n", ""))

proc getBridge*(bridges: seq[Bridge], bridgeName: string): Bridge =
  for bridge in bridges:
    if bridge.name == bridgeName:
      return bridge

  exception(fmt"Bridge object not found: '{bridgeName}'")

proc getNetworkInterface*(bridge: Bridge,
                          containerId: string): NetworkInterface =

  for iface in bridge.ifaces:
    if iface.containerId == containerId:
      return iface

  exception(fmt"NetworkInterface object not found: '{containerId}'")

# TODO: Move
proc isDigit*(str: string): bool =
  for c in str:
    if not isDigit(c): return false
  return true

proc ipAddressValidate(str: string): bool =
  let splited = str.split('.')
  if splited.len == 4:
    for str in splited:
      if not isDigit(str): return false
    return true

proc parseIpAdder*(str: string): IpAddr =
  let splited = str.split("/")

  if splited.len == 1 and ipAddressValidate(splited[0]):
    return IpAddr(address: splited[0], subnetMask: none(int))
  elif splited.len == 2:
    if ipAddressValidate(splited[0]) and isDigit(splited[1]):
      return IpAddr(address: splited[0], subnetMask: some(parseInt(splited[1])))
    else:
      exception(fmt"Failed to parseIpAdder: '{str}'")
  else:
    exception(fmt"Failed to parseIpAdder: '{str}'")

proc `$`(ipAddr: IpAddr): string =
  result = ipAddr.address
  if ipAddr.subnetMask.isSome:
    result &= "/" & $ipAddr.subnetMask.get

proc initVeth(name: string, ipAddr: IpAddr): Veth =
  return Veth(name: name, ipAddr: some(ipAddr))

proc initNetworkInterface(containerId: string,
                          veth, brVeth: Veth): NetworkInterface =

  return NetworkInterface(containerId: containerId,
                          veth: some(veth),
                          brVeth: some(brVeth))

proc initBridge*(bridgeName: string): Bridge =
  let
    rtVethIpAddr = some(defaultBridgeIpAddr())
    rtVeth = Veth(name: defaultRtBridgeVethName(), ipAddr: rtVethIpAddr)
    brRtVeth = Veth(name: defaultRtRtBridgeVethName())

  return Bridge(name: bridgeName,
                rtVeth: some(rtVeth),
                brRtVeth: some(brRtVeth),
                ifaces: @[])

proc toIpAddr(json: JsonNode): IpAddr =
  result.address = json["address"].getStr

  if json["subnetMask"]["has"].getBool:
    let subnetMask = json["subnetMask"]["val"].getInt
    result.subnetMask = some(subnetMask)

proc toVeth(json: JsonNode): Veth =
  result.name = json["name"].getStr

  if json["ipAddr"]["has"].getBool:
    let ipAddr = toIpAddr(json["ipAddr"]["val"])
    result.ipAddr = some(ipAddr)

proc toNetworkInterface(json: JsonNode): NetworkInterface =
  let containerId = json["containerId"].getStr

  result.containerId = containerId

  if json["veth"]["has"].getBool:
    let veth = toVeth(json["veth"]["val"])
    result.veth = some(veth)

  if json["brVeth"]["has"].getBool:
    let brVeth = toVeth(json["brVeth"]["val"])
    result.brVeth = some(brVeth)

proc toBridge(json: JsonNode): Bridge =
  result.name = json["name"].getStr

  if json["rtVeth"]["has"].getBool:
    let rtVeth = toVeth(json["rtVeth"]["val"])
    result.rtVeth = some(rtVeth)

  if json["brRtVeth"]["has"].getBool:
    let brRtVeth = toVeth(json["brRtVeth"]["val"])
    result.brRtVeth = some(brRtVeth)

  if json["ifaces"].len > 0:
    for ifaceJson in json["ifaces"].items:
      result.ifaces.add toNetworkInterface(ifaceJson)

proc toNetwork(json: JsonNode): Network =
  for b in json["bridges"]:
    result.bridges.add toBridge(b)

proc getVethName*(iface: NetworkInterface): Option[string] =
  if iface.veth.isSome:
    return some(iface.veth.get.name)

proc getBrVethName*(iface: NetworkInterface): Option[string] =
  if iface.brVeth.isSome:
    return some(iface.brVeth.get.name)

# Write/Overwrite a network_state.json
proc updateNetworkState*(network: Network, networkStatePath: string) =
  let (dir, _, _) = networkStatePath.splitFile
  if not dirExists(dir):
    createDir(runPath())

  let json = $$network
  writeFile(networkStatePath, $json)

# Read a network_state.json
# If a network_state.json doesn't exist, return a new Network object.
proc loadNetworkState*(networkStatePath: string): Network =
  if fileExists(networkStatePath):
    try:
      let json = parseFile(networkStatePath)
      return json.toNetwork
    except: exception(fmt"Failed to parse network_state.json. Please check {networkStatePath}")
  else:
    return Network(bridges: @[])

proc getCurrentBridgeIndex*(
  bridges: seq[Bridge], bridgeName: string): Option[int] =

  for index, b in bridges:
    if b.name == bridgeName:
      return some(index)

proc newVethName(iface: seq[NetworkInterface], baseName: string): string =
  var countVeth = 0
  for i in iface:
    if i.veth.isSome:
      countVeth.inc

  return baseName & $countVeth

proc newBrVethName(iface: seq[NetworkInterface], baseName: string): string =
  var countBrVeth = 0
  for i in iface:
    if i.veth.isSome:
      countBrVeth.inc

  return baseName & $countBrVeth

proc getRightEndNum(ipAddr: IpAddr): int =
  let
    splitedIpAddr = ipAddr.address.split("/")
    numStr = (splitedIpAddr[0].join.split("."))[^1]

  try: return numStr.parseInt
  except: exception(fmt"Failed to parse int: '{numStr}'")

proc newVethIpAddr(iface: seq[NetworkInterface]): string =
  var maxNum = 1
  for ip in iface:
    if ip.veth.isSome and ip.veth.get.ipAddr.isSome:
      let
        num = getRightEndNum(ip.veth.get.ipAddr.get)
      if num > maxNum:
        maxNum = num

    if ip.brVeth.isSome and ip.brVeth.get.ipAddr.isSome:
      let
        num = getRightEndNum(ip.brVeth.get.ipAddr.get)
      if num > maxNum:
        maxNum = num

  return fmt"10.0.0.{maxNum + 1}"

# Add a new iface to Bridge.iface
proc addNewNetworkInterface*(bridge: var Bridge,
                             containerId, baseVethName, baseBrVethName: string,
                             isBridgeMode: bool) =

  var iface = NetworkInterface(containerId: containerId)

  if isBridgeMode:
    block:
      let
        vethName = newVethName(bridge.ifaces, baseVethName)
        ipAddr = IpAddr(address: newVethIpAddr(bridge.ifaces), subnetMask: some(24))
        veth = Veth(name: vethName, ipAddr: some(ipAddr))
      iface.veth = some(veth)

    block:
      let
        brVethName = newBrVethName(bridge.ifaces, baseBrVethName)
        brVeth = Veth(name: brVethName, ipAddr: none(IpAddr))
      iface.brVeth = some(brVeth)
  else:
    iface.veth = none(Veth)
    iface.brVeth = none(Veth)

  bridge.ifaces.add iface

proc add*(bridge: var Bridge, iface: NetworkInterface) =
  bridge.ifaces.add(iface)

proc addIpToNetworkInterface(containerId, ipAddr: string) =
  const filePath = networkStatePath()

  if fileExists(filePath):
    let json = try:
                 parseFile(filePath)
               except:
                 echo fmt"Failed to parseFile: '{filePath}'"
                 quit(1)

    if json.contains("ips"):
      var iface = json["ips"]
      iface.add(%* {containerId: ipAddr})

      let newJson = %* {"ips": iface}
      writeFile(filePath, $newJson)
  else:
    let json = %* {"ips": [{containerId: ipAddr}]}

    try: createDir(runPath())
    except: exception(fmt"Failed to create a directory: '{runPath()}'")

    try: writeFile(filePath, $json)
    except: exception(fmt"Failed to write a json: '{filePath}'")

proc removeIpFromNetworkInterface*(network: var Network, bridgeName, containerId: string) =
  for bridgeIndex, b in network.bridges:
    if b.name == bridgeName:
      for ifaceIndex, iface in b.ifaces:
        if iface.containerId == containerId:
          network.bridges[bridgeIndex].ifaces.delete(ifaceIndex .. ifaceIndex)
          return

proc checkIfExistNetworkInterface(interfaceName: string): bool =
  const CMD = "ip a"
  let r = execCmdEx(CMD)

  if r.exitCode == 0:
    result = r.output.contains(interfaceName)

proc upNetworkInterface*(interfaceName: string) =
  let
    cmd = fmt"ip link set {interfaceName} up"
    r = execShellCmd(cmd)

  if r != 0:
    exception(fmt"Failed to '{cmd}': exitCode: {r}")

proc createVethPair*(hostInterfaceName, containerInterfaceName: string) =
  let
    cmd = fmt"ip link add name {hostInterfaceName} type veth peer name {containerInterfaceName}"
    r = execShellCmd(cmd)

  # r == 2 is already exist
  if r != 0 and r != 2:
    exception(fmt"Failed to '{cmd}': exitCode: {r}")

proc addIpAddrToVeth*(veth: Veth) =
  let
    ipAddr = veth.ipAddr.get
    interfaceName = veth.name
    cmd = fmt"ip addr add {ipAddr} dev {interfaceName}"
    r = execShellCmd(cmd)

  if r != 0:
    exception(fmt"Failed to '{cmd}': exitCode: {r}")

# Wait for a network interface to be ready.
proc waitInterfaceReady*(interfaceName: string) =
  let r = execCmdEx("ip a")
  if r.exitCode == 0:
    while true:
      if r.output.contains(interfaceName):
        break
  else:
    exception("Failed to ip command in container")

proc addInterfaceToContainer*(iface: NetworkInterface, pid: Pid) =
  block:
    let
      containerInterfaceName = iface.veth.get.name
      cmd = fmt"ip link set {containerInterfaceName} netns {$pid}"
      r = execShellCmd(cmd)

    if r != 0:
      exception(fmt"Failed to '{cmd}': exitCode: {r}")

  block:
    let hostInterfaceName = iface.brVeth.get.name
    upNetworkInterface(hostInterfaceName)

proc connectVethToBridge*(interfaceName, bridgeName: string) =
  let
    cmd = fmt"ip link set {interfaceName} master {bridgeName}"
    r = execShellCmd(cmd)

  if r != 0:
    exception(fmt"Failed to '{cmd}': exitCode {r}")

proc createBridge*(bridge: Bridge) =
  let
    bridgeName = bridge.name
    rtVethName = bridge.rtVeth.get.name
    brRtVethName = bridge.brRtVeth.get.name

  block:
    if not checkIfExistNetworkInterface(bridgeName):

      block:
        let
          cmd = fmt"ip link add name {rtVethName} type veth peer name {brRtVethName}"
          r = execShellCmd(cmd)

        if r != 0:
          exception(fmt"Failed to '{cmd}': exitCode: {r}")

      block:
        let
          cmd = fmt"ip link add {bridgeName} type bridge"
          r = execShellCmd(cmd)

        if r != 0:
          exception(fmt"Failed to '{cmd}': exitCode: {r}")

      block:
        connectVethToBridge(brRtVethName, bridgeName)

  block:
    let
      ipAddr = bridge.rtVeth.get.ipAddr.get
      cmd = fmt"ip addr add {ipAddr} dev {rtVethName}"
      r = execShellCmd(cmd)

    if r != 0:
      exception(fmt"Failed to '{cmd}': exitCode {r}")

  upNetworkInterface(brRtVethName)
  upNetworkInterface(rtVethName)
  upNetworkInterface(bridgeName)

# Check if an iptables rule already exists.
# Use "iptables -C"
proc iptablesRuleExist(rule: string): bool =
  let
    cmd = rule.replace(" -A ", " -C ") & "; echo $?"
    r = execCmdEx(cmd)

  # 0 is already exist
  if r.output == "0\n":
    return true

proc setNat*(interfaceName: string, ipAddr: IpAddr) =
  let cmd = fmt"iptables -t nat -A POSTROUTING -s {ipAddr} -o {interfaceName} -j MASQUERADE"

  if not iptablesRuleExist(cmd):
    let r = execShellCmd(cmd)
    if r != 0:
      exception(fmt"Failed to '{cmd}': exitCode {r}")

proc setDefaultGateWay(ipAddr: IpAddr) =
  let
    address = ipAddr.address
    cmd = fmt"ip route add default via {address}"
    r = execShellCmd(cmd)

  if r != 0:
    exception(fmt"Failed to '{cmd}': exitCode {r}")

proc setPortForward*(vethIpAddr: IpAddr, portPair: PublishPortPair) =
  let
    hPort = portPair.host
    cPort = portPair.container

    # TODO: Remove
    hostAddress = getPrimaryIpOfHost()

    containerAddress = vethIpAddr.address

  # External traffic
  block:
    let cmd = fmt"iptables -t nat -A PREROUTING -d {hostAddress} -p tcp -m tcp --dport {hPort} -j DNAT --to-destination {containerAddress}:{cPort}"

    if not iptablesRuleExist(cmd):
      let r = execShellCmd(cmd)
      if r != 0:
        exception(fmt"Failed to '{cmd}': exitCode {r}")

  # Local traffic
  block:
    let cmd = fmt "iptables -t nat -A OUTPUT -d {hostAddress} -p tcp -m tcp --dport {hPort} -j DNAT --to-destination {containerAddress}:{cPort}"

    if not iptablesRuleExist(cmd):
      let r = execShellCmd(cmd)

      if r != 0:
        exception(fmt"Failed to '{cmd}': exitCode {r}")

proc removeIptablesRule(rule: string) =
  if rule.contains(" -A "):
    if iptablesRuleExist(rule):
      discard execShellCmd(rule.replace(" -A ", " -D "))
  elif rule.contains(" -D "):
    discard execShellCmd(rule)
  else:
    exception(fmt"Invalid iptables rule: '{rule}'")

proc removeContainerIptablesRule*(iface: NetworkInterface,
                                  portPair: PublishPortPair) =

  let
    veth = iface.veth.get

    # TODO: Remove
    hostAddress = getPrimaryIpOfHost()

    containerAddress = veth.ipAddr.get.address

    hPort = portPair.host
    cPort = portPair.container

  block:
    let cmd = fmt"iptables -t nat -D PREROUTING -d {hostAddress} -p tcp -m tcp --dport {hPort} -j DNAT --to-destination {containerAddress}:{cPort}"
    discard execShellCmd(cmd)

  block:
    let cmd = fmt "iptables -t nat -D OUTPUT -d {hostAddress} -p tcp -m tcp --dport {hPort} -j DNAT --to-destination {containerAddress}:{cPort}"
    discard execShellCmd(cmd)

  block:
    let
      # TODO: Remove
      ipAddr = defaultNatAddress()
      # TODO: Remove
      interfaceName = getDefaultNetworkInterface()

      cmd = fmt"iptables -t nat -D POSTROUTING -s {ipAddr} -o {interfaceName} -j MASQUERADE"

proc lockNetworkStatefile*(networkStatePath: string) {.inline.} =
  if fileExists(networkStatePath):
    moveFile(networkStatePath, lockedNetworkStatePath())

proc unlockNetworkStatefile*(networkStatePath: string) {.inline.} =
  if fileExists(lockedNetworkStatePath()):
    moveFile(lockedNetworkStatePath(), networkStatePath)

proc isLockedNetworkStateFile*(networkStatePath: string): bool {.inline.} =
  fileExists(lockedNetworkStatePath())

proc initContainerNetwork*(iface: NetworkInterface, rtVethIpAddr: IpAddr) =
  # Up loopback interface
  block:
    const LOOPBACK_INTERFACE= "lo"
    upNetworkInterface(LOOPBACK_INTERFACE)

  # Wait for a network interface to be ready.
  let vethName = iface.getVethName.get

  waitInterfaceReady(vethName)

  addIpAddrToVeth(iface.veth.get)
  upNetworkInterface(vethName)

  setDefaultGateWay(rtVethIpAddr)

proc initNicoruNetwork*(networkStatePath: string): Network =
  const BRIDGE_NAME = defaultBridgeName()

  result = loadNetworkState(networkStatePath)

  if result.bridges.len == 0:
    result.bridges.add initBridge(BRIDGE_NAME)

  if not bridgeExists(BRIDGE_NAME):
    createBridge(result.bridges[0])
