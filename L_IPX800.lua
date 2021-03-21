local MSG_CLASS = "IPX800"
local IPX800_SERVICE = "urn:upnp-org:serviceId:IPX8001"
local DEVICE_TYPE = "urn:schemas-upnp-org:device:IPX800:1"
local DEBUG_MODE = false
local version = "v0.57"
local UI7_JSON_FILE= "D_IPX800_UI7.json"
local DEFAULT_DELAY = 60
local RAND_DELAY = 10	-- startup delay

local http = require("socket.http")
local ltn12 = require("ltn12")
local lom = require("lxp.lom") -- http://matthewwild.co.uk/projects/luaexpat/lom.html
local xpath = require("xpath")
local json = require("L_IPX800json")
local mime = require("mime")

local inputRelaysPattern = "(%d+)([PDM]?)"
local analogInputPattern = "(%d+)([TLH]?)"
local outputRelaysPattern = "(%d+)([PW]?.*)"

local mapCodeToDeviceType = {
	["W"] = { 
		DType = "urn:schemas-micasaverde-com:device:WindowCovering:1",
		DFile = "D_WindowCovering1.xml"
	},
	["P"] = { 
		DType = "urn:schemas-upnp-org:device:BinaryLight:1",
		DFile = "D_BinaryLight1.xml"
	},
	["D"] = { 
		DType = "urn:schemas-micasaverde-com:device:DoorSensor:1",
		DFile = "D_DoorSensor1.xml"
	},
	["M"] = { 
		DType = "urn:schemas-micasaverde-com:device:MotionSensor:1",
		DFile = "D_MotionSensor1.xml"
	},
	["T"] = { 
		DType = "urn:schemas-micasaverde-com:device:TemperatureSensor:1",
		DFile = "D_TemperatureSensor1.xml"
	},
	["L"] = { 
		DType = "urn:schemas-micasaverde-com:device:LightSensor:1",
		DFile = "D_LightSensor1.xml"
	},
	["H"] = { 
		DType = "urn:schemas-micasaverde-com:device:HumiditySensor:1",
		DFile = "D_HumiditySensor1.xml"
	}
}

--calling a function from HTTP in the device context
--http://192.168.1.5/port_3480/data_request?id=lu_action&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&action=RunLua&DeviceNum=81&Code=getMapUrl(81)

------------------------------------------------
-- Debug --
------------------------------------------------
local function log(text, level)
	luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

local function debug(text)
	if (DEBUG_MODE) then
		log("debug: " .. text)
	end
end

local function warning(stuff)
	log("warning: " .. stuff, 2)
end

local function error(stuff)
	log("erreur: " .. stuff, 1)
end

function setDebugMode(lul_device,newDebugMode)
	lul_device = tonumber(lul_device)
	newDebugMode = tonumber(newDebugMode) or 0
	debug(string.format("setDebugMode(%d,%d)",lul_device,newDebugMode))
	luup.variable_set(IPX800_SERVICE, "Debug", newDebugMode, lul_device)
	if (newDebugMode==1) then
		DEBUG_MODE=true
	else
		DEBUG_MODE=false
	end
end

------------------------------------------------
-- Check UI7
------------------------------------------------
local function checkVersion()
	local ui7Check = luup.variable_get(IPX800_SERVICE, "UI7Check", lug_device) or ""
	if ui7Check == "" then
		luup.variable_set(IPX800_SERVICE, "UI7Check", "false", lug_device)
		ui7Check = "false"
	end
	if( luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
		luup.variable_set(IPX800_SERVICE, "UI7Check", "true", lug_device)
		luup.attr_set("device_json", UI7_JSON_FILE, lug_device)
		luup.reload()
	end
end
------------------------------------------------
-- Tasks
------------------------------------------------
local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

--
-- Has to be "non-local" in order for MiOS to call it :(
--
local function task(text, mode)
	if (mode == TASK_ERROR_PERM)
	then
		error(text)
	elseif (mode ~= TASK_SUCCESS)
	then
		warning(text)
	else
		log(text)
	end
	if (mode == TASK_ERROR_PERM)
	then
		taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
	else
		taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

		-- Clear the previous error, since they're all transient
		if (mode ~= TASK_SUCCESS)
		then
			luup.call_delay("clearTask", 15, "", false)
		end
	end
end

function clearTask()
	task("Clearing...", TASK_SUCCESS)
end

function UserMessage(text, mode)
	mode = (mode or TASK_ERROR)
	task(text,mode)
end

------------------------------------------------
-- LUA Utils
------------------------------------------------
local function Split(str,sep)
	local sep, fields = sep or ":", {}
	local pattern = string.format("([^%s]+)", sep)
	str:gsub(pattern, function(c) fields[#fields+1] = c end)
	return fields
end

-- function string:split(sep) -- from http://lua-users.org/wiki/SplitJoin
	-- return Split(self,sep)
-- end

function string:template(variables)
	return (self:gsub('{(.-)}', 
		function (key) 
			return tostring(variables[key] or '') 
		end))
end

function string:trim()
  return self:match "^%s*(.-)%s*$"
end

------------------------------------------------
-- Escape quote characters (for string comp)
------------------------------------------------
local function escapeQuotes( str )
		return str:gsub("\'", "\\'"):gsub("\?", '\\?'):gsub('\"','\\"') -- escape quote characters
end

------------------------------------------------
-- XML utils
------------------------------------------------
function extractElement(tag, condition, xml, default )
	local pattern = "<"..tag.."%s+.*"..condition ..".*>(.*)</"..tag..">"
	debug("pattern:"..pattern)
	local result = (xml:match(pattern) or default)
	return result
end


-- example: iterateTbl( t , luup.log )
local function forEach( tbl, func, param )
	for k,v in pairs(tbl) do
		func(k,v,param)
	end
end

local function round(val, decimal)
  local exp = decimal and 10^decimal or 1
  return math.ceil(val * exp - 0.5) / exp
end

local function url_encode(str)
  if (str) then
	str = string.gsub (str, "\n", "\r\n")
	str = string.gsub (str, "([^%w %-%_%.%~])",
		function (c) return string.format ("%%%02X", string.byte(c)) end)
	str = string.gsub (str, " ", "+")
  end
  return str	
end

------------------------------------------------
-- VERA Device Utils
------------------------------------------------

local function getParent(lul_device)
	return luup.devices[lul_device].device_num_parent
end

local function getAltID(lul_device)
	return luup.devices[lul_device].id
end

local function findDeviceFromMacAddress(mac)
	for k,v in pairs(luup.devices) do
		if (v.mac == mac ) then
			return k,v
		end
	end
	return nil,nil
end

-----------------------------------
-- from a altid, find a child device
-- returns 2 values
-- a) the index === the device ID
-- b) the device itself luup.devices[id]
-----------------------------------
local function findChild( lul_parent, altid )
	debug(string.format("findChild(%s,%s)",lul_parent,altid))
	for k,v in pairs(luup.devices) do
		if( getParent(k)==lul_parent) then
			if( v.id==altid) then
				return k,v
			end
		end
	end
	return nil,nil
end

local function getRoot(lul_device)
	while( getParent(lul_device)>0 ) do
		lul_device = getParent(lul_device)
	end
	return lul_device
end

local function forEachChildren(parent, func, param )
	--debug(string.format("forEachChildren(%s,func,%s)",parent,param))
	for k,v in pairs(luup.devices) do
		if( getParent(k)==parent) then
			func(k, param)
		end
	end
end

local function getForEachChildren(parent, func, param )
	--debug(string.format("forEachChildren(%s,func,%s)",parent,param))
	local result = {}
	for k,v in pairs(luup.devices) do
		if( getParent(k)==parent) then
			result[#result+1] = func(k, param)
		end
	end
	return result
end

local function getSetVariable(serviceId, name, deviceId, default)
	local curValue = luup.variable_get(serviceId, name, deviceId)
	if (curValue == nil) then
		curValue = default
		luup.variable_set(serviceId, name, curValue, deviceId)
	end
	return curValue
end

local function setVariableIfChanged(serviceId, name, value, deviceId)
	debug(string.format("setVariableIfChanged(%s,%s,%s,%s)",serviceId, name, value, deviceId))
	local curValue = luup.variable_get(serviceId, name, deviceId) or ""
	value = value or ""
	if (tostring(curValue)~=tostring(value)) then
		luup.variable_set(serviceId, name, value, deviceId)
	end
end

local function setAttrIfChanged(name, value, deviceId)
	debug(string.format("setAttrIfChanged(%s,%s,%s)",name, value, deviceId))
	local curValue = luup.attr_get(name, deviceId)
	if ((value ~= curValue) or (curValue == nil)) then
		luup.attr_set(name, value, deviceId)
		return true
	end
	return value
end

------------------------------------------------------------------------------------------------
-- Http handlers : Communication FROM IPX800
-- http://192.168.1.5:3480/data_request?id=lr_IPX800_Handler&command=xxx
-- recommended settings in IPX800: PATH = /data_request?id=lr_IPX800_Handler&mac=$M&deviceID=114
------------------------------------------------------------------------------------------------
function switch( command, actiontable)
	-- check if it is in the table, otherwise call default
	if ( actiontable[command]~=nil ) then
		return actiontable[command]
	end
	warning("myIPX800_Handler:Unknown command received:"..command.." was called. Default function")
	return actiontable["default"]
end

function myIPX800_Handler(lul_request, lul_parameters, lul_outputformat)
	log('myIPX800_Handler: request is: '..tostring(lul_request))
	log('myIPX800_Handler: parameters is: '..json.encode(lul_parameters))
	log('myIPX800_Handler: outputformat is: '..json.encode(lul_outputformat))
	local lul_html = "";	-- empty return by default
	
	-- find a parameter called "command"
	if ( lul_parameters["command"] ~= nil ) then
		command =lul_parameters["command"]
	else
	    debug("myIPX800_Handler:no command specified, taking default")
		command ="default"
	end
	
	local deviceID = tonumber(lul_parameters["DeviceNum"] or -1)
	
	-- switch table
	local action = {
		["default"] = function(params)	
				--luup.call_timer("refreshDevice",1,1,"",114)
				local devid = lul_parameters["deviceID"]
				if (devid==nil) then
					local mac = lul_parameters["mac"]
					if (mac~=nil) then
						warning(string.format("deviceID parameter not specified in the PUSH parameters, trying to match MAC address:%s",mac))
						devid = findDeviceFromMacAddress(mac)
					else
						error("neither deviceID or MAC parameter is  specified in the PUSH parameters, cannot update VERA")
					end
				end
				if (devid~=nil) then
					devid= tonumber(devid)
					debug("devid:"..devid)
					if (luup.devices[devid]~=nil) then
						local dtype = luup.devices[devid].device_type
						debug(string.format("device type:%s",dtype))
						if (dtype==DEVICE_TYPE) then
							local firmwareVersion= getSetVariable(IPX800_SERVICE,"FirmwareVersion", lul_device, "")
							debug(string.format("firmware of IPX card is %s",firmwareVersion))
							local major,minor,dot = firmwareVersion:match("(%d+).(%d+).(%d+)")
							major,minor,dot = tonumber(major), tonumber(minor), tonumber(dot)
							-- if (major==3) and (minor==5) and (dot<=42) then
								if (refreshDevice(devid,true) == true) then
									return "ok"
								end
							-- end
						else
							warning(string.format("IPX800 Handler method called for device %d which is not the right type:%s",devid,dtype))
						end
					else
						warning(string.format("IPX800 Handler method called for an unknown device id: %d, ignoring",devid))
					end
				end
				return "not successful"
			end
	}
	-- actual call
	lul_html = switch(command,action)(lul_parameters) or ""
	debug(string.format("lul_html:%s",lul_html))
	return lul_html,"text/html"
end

------------------------------------------------
-- Communication TO IPX800
------------------------------------------------
function ipx800HttpCall(lul_device,cmd)
	lul_device = tonumber(lul_device)
	log(string.format("ipx800HttpCall(%d,%s)",lul_device,cmd))
	local user= getSetVariable(IPX800_SERVICE,"User", lul_device, "")
	local password= getSetVariable(IPX800_SERVICE,"Password", lul_device, "")
	local myheaders={}
	--[http://][<user>[:<password>]@]<host>[:<port>][/<path>] 
	-- =====================================================================
	--  Big WARNNG : IPX800 does not support lowercase headers so it
	--  requires "Authorization" as the header,  while VERA/LUA sends "authorization"
	--  and it fails
	-- cf => http://forum.micasaverde.com/index.php?topic=13081.0
	-- =====================================================================
	if (user~=nil) and (user~="") then
		local b64credential = "Basic ".. mime.b64(user..":"..password)
		myheaders={
			--["Accept"]="text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
			["Authorization"]=b64credential, --"Basic " + b64 encoded string of user:pwd
		}
	end
	local ip_address = getSetVariable(IPX800_SERVICE,"IpxIpAddress", lul_device, "ipx800_v3") or "ipx800_v3"
	local url = string.format ("http://%s/%s", ip_address,cmd)
	debug("url:"..url)
	debug("myheaders:"..json.encode(myheaders))
	
	local result = {}
	local request, code = http.request({
		url = url,
		headers = myheaders,
		sink = ltn12.sink.table(result)
	})
	
	-- fail to connect
	if (request==nil) then
		error(string.format("failed to connect to %s, http.request returned nil", ip_address))
		return nil
	elseif (code==401) then
		warning(string.format("Access to IPX requires a user/password: %d", code))
		return "unauthorized"
	elseif (code~=200) then
		warning(string.format("http.request returned a bad code: %d", code))
		return nil
	end
	
	-- everything looks good
	local data = table.concat(result)
	debug(string.format("request:%s",request))	
	debug(string.format("code:%s",code))	
	--debug(string.format("data:%s",data))	
	return data
end

-- Commander une sortie : http://IPX800_V3/leds.cgi?
-- Param�tre :
-- led=x avec x le num�ro de la sortie, de 0 � 31.
-- Cette syntaxe permet la commande directe d'une sortie. Cette syntaxe commandera une impulsion si la sortie concern�e a �t� pr�r�gl�e avec au
-- moins un Tb non nul dans le site embarqu� de l'IPX. Sinon la commande inversera tout simplement l'�tat de la sortie, comme un t�l�rupteur.
function setIPXLed(lul_device,num,value)		
	lul_device = tonumber(lul_device)
	num = tonumber(num)
	value = tonumber(value)
	debug(string.format("setIPXLed(%d,%d,%d)",lul_device,num,value))
	local cmd=""
	if (value==0) then
		-- sortie sans mode impulsionel
		cmd = string.format("preset.htm?set%d=%d",num+1,value)
	else
		-- sortie according to configuration of Tb inside IPX800 ( impulse or normal )
		cmd = string.format("leds.cgi?led=%d",num)
	end
	ipx800HttpCall(getRoot(lul_device),cmd)
end

function setIPXInput(lul_device,num,value)	
	lul_device = tonumber(lul_device)
	num = tonumber(num)
	value = tonumber(value)
	debug(string.format("setIPXInput(%d,%d,%d)",lul_device,num,value))
	local cmd = string.format("leds.cgi?led=%d",100+num)
	ipx800HttpCall(getRoot(lul_device),cmd)
end

------------------------------------------------
-- find name in relay settings page of IPX !
-- could be dangerous code if GCE changes or if the user
-- created custom pages
------------------------------------------------
-- num : 0, 31
function getIpxRelayName(lul_device,num)
	--   <input type="text"  maxlength="28" name="relayname" style="width:260px;margin-left:5px;" value ="Relay1"/> 

	lul_device = tonumber(lul_device)
	num = tonumber(num or 0)
	debug(string.format("getIpxRelayName(%d,%d)",lul_device,num))
	local xmldata = ipx800HttpCall(lul_device,"protect/settings/output1.htm?oselect="..(num+32))
	local pattern = "<input.-name=\"relayname\".-value.-\"(.-)\"/>"
	local result = (xmldata:match(pattern) or "")
	debug("Name from IPX output1.htm page:"..result )
	return result
end

-- num : 0, 15 
function getIpxAnalogName(lul_device,num)
	lul_device = tonumber(lul_device)
	num = tonumber(num or 0)
	debug(string.format("getIpxAnalogName(%d,%d)",lul_device,num))
	local xmldata = ipx800HttpCall(lul_device,"protect/assignio/analog"..(num+1)..".htm")
	local pattern = "<input.-name=\"name\".-value.-\"(.-)\"/>"
	local result = (xmldata:match(pattern) or "")
	debug("Name from IPX analogx.htm page:"..result )
	return result
end

-- num : 0,31
function getIpxInputName(lul_device,num)
	lul_device = tonumber(lul_device)
	num = tonumber(num or 0)
	debug(string.format("getIpxInputName(%d,%d)",lul_device,num))
	--http://192.168.1.10/protect/assignio/assign1.htm?isel=0
	local xmldata = ipx800HttpCall(lul_device,"protect/assignio/assign1.htm?isel="..num)
	local pattern = "<input.-name=\"inputname\".-value.-\"(.-)\" />"
	local result = (xmldata:match(pattern) or "")
	debug("Name from IPX assign1.htm page:"..result )
	return result
end

------------------------------------------------
-- CHILDREN Actions
------------------------------------------------
function setLoadLevel(lul_device,newLoadlevelTarget)
	lul_device = tonumber(lul_device)
	newLoadlevelTarget = tonumber(newLoadlevelTarget)
	debug(string.format("setLoadLevel(%d,%d)",lul_device,newLoadlevelTarget))
	luup.variable_set("urn:upnp-org:serviceId:Dimming1", "LoadLevelTarget", newLoadlevelTarget, lul_device)
	luup.variable_set("urn:upnp-org:serviceId:Dimming1", "LoadLevelStatus", newLoadlevelTarget, lul_device)
end

function setArmed(lul_device,newArmedValue)
	lul_device = tonumber(lul_device)
	newArmedValue = tonumber(newArmedValue)
	debug(string.format("setArmed(%d,%d)",lul_device,newArmedValue))
	luup.variable_set("urn:micasaverde-com:serviceId:SecuritySensor1", "Armed", newArmedValue, lul_device)
end

function setTripped(lul_device,newTrippedValue)
	lul_device = tonumber(lul_device)
	newTrippedValue = tonumber(newTrippedValue)
	debug(string.format("setTripped(%d,%d)",lul_device,newTrippedValue))
	setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", newTrippedValue, lul_device)
	-- luup.variable_set("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", newTrippedValue, lul_device)
end

function getCurrentTemperature(lul_device)
	lul_device = tonumber(lul_device)
	debug(string.format("getCurrentTemperature(%d)",lul_device))
	return luup.variable_get("urn:upnp-org:serviceId:TemperatureSensor1", "CurrentTemperature", lul_device)
end

function setCurrentTemperature(lul_device,newTargetValue)
	lul_device = tonumber(lul_device)
	debug(string.format("setCurrentTemperature(%d,%.1f)",lul_device,newTargetValue))
	local v = string.format("%.1f",newTargetValue)
	setVariableIfChanged("urn:upnp-org:serviceId:TemperatureSensor1", "CurrentTemperature", v, lul_device)
	-- luup.variable_set("urn:upnp-org:serviceId:TemperatureSensor1", "CurrentTemperature", v, lul_device)
end

function setPowerTarget(lul_device,newTargetValue)
	lul_device = tonumber(lul_device)
	newTargetValue = tonumber(newTargetValue)
	debug(string.format("setPowerTarget(%d,%d)",lul_device,newTargetValue))
	setVariableIfChanged("urn:upnp-org:serviceId:SwitchPower1", "Status", newTargetValue, lul_device)
	-- luup.variable_set("urn:upnp-org:serviceId:SwitchPower1", "Status", newTargetValue, lul_device)
end

function setCurrentLightLevel(lul_device,newTargetValue)
	lul_device = tonumber(lul_device)
	debug(string.format("setCurrentLightLevel(%d,%.1f)",lul_device,newTargetValue))
	local v = string.format("%.1f",newTargetValue)
	luup.variable_set("urn:micasaverde-com:serviceId:LightSensor1", "CurrentLevel", v, lul_device)
end

function setCurrentHumidity(lul_device,newTargetValue)
	lul_device = tonumber(lul_device)
	debug(string.format("setCurrentHumidity(%d,%.1f)",lul_device,newTargetValue))
	local v = string.format("%.1f",newTargetValue)
	luup.variable_set("urn:micasaverde-com:serviceId:HumiditySensor1", "CurrentLevel", v, lul_device)
end

------------------------------------------------
-- Device Properties Utils
------------------------------------------------
function getOutputDeviceType(lul_device,num)
	local tbl = {}
	local outputRelays= getSetVariable(IPX800_SERVICE,"OutputRelays", getParent(lul_device), "")
	for k,v in pairs(Split(outputRelays,",")) do
		local i,t = string.match(v,outputRelaysPattern)	-- device & type W:windowcover
		i = tonumber(i)
		if (num==i) then
			if (t==nil) or (t=="") then
				tbl[1] = "P"
				return tbl
			end
			-- t = W-2-3-30-40
			tbl = Split(t,"-")
			if (tbl[4]==nil) then
				tbl[4]=DEFAULT_DELAY
				tbl[5]=DEFAULT_DELAY
			else
				if (tbl[5]==nil) then
					tbl[5]=tbl[4]
				end
			end
			return tbl
		end
	end
	warning(string.format("getOutputDeviceType could not find num:%s in %s",num,outputRelays))
	tbl[1] = "P"
	return tbl
end		

function getInputDeviceType(lul_device,num)
	local inputRelays= getSetVariable(IPX800_SERVICE,"InputRelays", getParent(lul_device), "")
	for k,v in pairs(Split(inputRelays,",")) do
		local i,t = string.match(v,inputRelaysPattern)	-- device & type P:powerswitch M:motionsensor
		i = tonumber(i)
		if (num==i) then
			if (t==nil) or (t=="") then
				t="P"
			end
			return t -- defaults to power device
		end
	end
	warning(string.format("getInputDeviceType could not find num:%s in %s",num,inputRelays))
	return "P"
end		

function getAnalogDeviceType(lul_device,num)
	local analogInputs= getSetVariable(IPX800_SERVICE,"AnalogInputs", getParent(lul_device), "")
	for k,v in pairs(Split(analogInputs,",")) do
		local i,t = string.match(v,analogInputPattern)	-- device & type T:temperature L:Lux Lumiere H:Humidity
		i = tonumber(i)
		if (num==i) then
			if (t==nil) or (t=="") then
				t="T"
			end
			return t -- defaults to temp device
		end
	end
	warning(string.format("getAnalogDeviceType could not find num:%s in %s",num,analogInputs))
	return "T"
end	

--
--return ipxtype ( led,btn,ana ) , vera dev code type ( P, M, T )
-- 
function getDeviceInformation(lul_device,name)
	lul_device = tonumber(lul_device)
	debug(string.format("getDeviceInformation(%d,%s)",lul_device,name))
	local ipxtype = name:sub(1,3)
	local num = nil
	local typ = ""
	local opt = ""
	local tbl = {}
	if (ipxtype == "led") then
		num = tonumber( string.match( name, "led(%d+)") )
		tbl = getOutputDeviceType(lul_device,num+1)
		typ = tbl[1]
	elseif (ipxtype == "btn") then
		num = tonumber( string.match( name, "btn(%d+)") )
		typ = getInputDeviceType(lul_device,num+1)
	elseif (ipxtype == "ana") then
		num = tonumber( string.match( name, "analog(%d+)") )
		typ = getAnalogDeviceType(lul_device,num+1)
	end
	debug(string.format("ipxtype:%s,num:%s,type:%s",ipxtype,num,typ))
	return ipxtype,num,typ,tbl
end


function UserSetPowerTarget(lul_device,newTargetValue)
	debug(string.format("UserSetPowerTarget(%s,%s)",lul_device,newTargetValue))
	local status = luup.variable_get("urn:upnp-org:serviceId:SwitchPower1", "Status", lul_device)
	if (status ~= newTargetValue) then
		setPowerTarget(lul_device,newTargetValue)
		local name = getAltID(lul_device)
		if (name:sub(1,3) == "led") then
			local num = tonumber( string.match( name, "led(%d+)") )
			setIPXLed(lul_device,num,newTargetValue)
		elseif (name:sub(1,3) == "btn") then
			local num = tonumber( string.match( name, "btn(%d+)") )
			setIPXInput(lul_device,num,newTargetValue)	
		end
	else
		debug(string.format("UserSetPowerTarget(%s,%s) - same status, ignoring",lul_device,newTargetValue))
	end
end

function UserSetArmed(lul_device,newArmedValue)
	debug(string.format("UserSetArmed(%s,%s)",lul_device,newArmedValue))
	return setArmed(lul_device,newArmedValue)
end

function StopWindowCovering(params)
	local data = json.decode(params)
	debug(string.format("StopWindowCovering(device:%s relay:%d )",data["device"],data["relay"]))
	setIPXLed(data["device"],data["relay"],1)		-- relay for up is this altid
end

function UserWindowCovering(lul_device,action,newLoadlevelTarget)
	debug(string.format("UserWindowCovering(%s,%s,%d)",lul_device,action,newLoadlevelTarget))
	newLoadlevelTarget = tonumber(newLoadlevelTarget or 0)
	setVariableIfChanged("urn:upnp-org:serviceId:Dimming1", "LoadLevelTarget", newLoadlevelTarget, lul_device)
	local name = getAltID(lul_device)
	local ipxtype,ipxnum,veratype,options = getDeviceInformation(lul_device,name)
	if (ipxtype=="led") and (veratype=="W") then
		local old = getSetVariable("urn:upnp-org:serviceId:Dimming1", "LoadLevelStatus", lul_device, 0)	
		old = tonumber(old)
		local percentage = math.abs(newLoadlevelTarget - old)
		local whichdelay = 4
		-- W-2-3-30
		if (action=="up") then
			setLoadLevel(lul_device,newLoadlevelTarget)
			setIPXLed(lul_device,ipxnum,1)		-- relay for up is this altid
			whichdelay=4
		elseif (action=="down") then
			setLoadLevel(lul_device,newLoadlevelTarget)
			setIPXLed(lul_device,tonumber(options[3])-1,1)	-- relay for down is #3
			whichdelay=5
		elseif (action=="stop") then
			setIPXLed(lul_device,tonumber(options[2])-1,1)	-- relay for stop is #2
		end
		-- let it run the full cycle if it goes for 0 or 100
		if (newLoadlevelTarget~=0) and (newLoadlevelTarget~=100) then
			-- if percent is not 100 , we need to stop a STOP command after some time
			local delay = math.floor(tonumber(options[whichdelay]) * math.abs(newLoadlevelTarget-old)/100)
			debug(string.format("Programming stop in %d seconds",delay))
			local data = {}
			data["device"]=lul_device
			data["relay"]=tonumber(options[2])-1
			luup.call_delay("StopWindowCovering", delay, json.encode(data))	
			-- setVariableIfChanged("urn:upnp-org:serviceId:Dimming1", "LoadLevelStatus", data["target"], data["device"])
		end
	end
end

function UserSetLoadLevelTarget(lul_device,newLoadlevelTarget)
	debug(string.format("UserSetLoadLevelTarget(%s,%d)",lul_device,newLoadlevelTarget))
	local old = getSetVariable("urn:upnp-org:serviceId:Dimming1", "LoadLevelStatus", lul_device, 0)	
	old = tonumber(old)
	newLoadlevelTarget = tonumber(newLoadlevelTarget)
	if (old<newLoadlevelTarget) then
		UserWindowCovering(lul_device,"up",newLoadlevelTarget)
	elseif (old>newLoadlevelTarget) then
		UserWindowCovering(lul_device,"down",newLoadlevelTarget)
	end
end

function IPXUpdatePowerTarget(lul_device,newTargetValue,veratype)
	debug("lul_device:"..lul_device)
	debug("newTargetValue:"..newTargetValue)
	debug(string.format("IPXUpdatePowerTarget(%s,%s) for type:%s",lul_device,newTargetValue,veratype))
	setPowerTarget(lul_device,newTargetValue)
end
		
function IPXUpdateInputButtonValue(lul_device,newTargetValue,veratype)
	lul_device = tonumber(lul_device)
	local inverted = getSetVariable(IPX800_SERVICE,"Inverted", lul_device, 0)
	debug(string.format("IPXUpdateInputButtonValue(%d,%s) for type:%s",lul_device,newTargetValue,veratype))

	if (veratype=="M") or (veratype=="D") then
		-- if MotionSensor
		if (inverted=="1") then
			newTargetValue = 1-newTargetValue
		end
		return setTripped(lul_device,newTargetValue)
	elseif (veratype=="P") then
		-- if PowerSwitch
		return setPowerTarget(lul_device,newTargetValue)
	end
	
end

function IPXUpdateSetAnalogValue(lul_device,newTargetValue,veratype)
	lul_device = tonumber(lul_device)
	debug(string.format("IPXUpdateSetAnalogValue(%d,%s) for type:%s",lul_device,newTargetValue,veratype))
	if (veratype=="T") then
		return setCurrentTemperature(lul_device,newTargetValue)
	elseif (veratype=="L") then
		return setCurrentLightLevel(lul_device,newTargetValue)
	elseif (veratype=="H") then
		return setCurrentHumidity(lul_device,newTargetValue)
	end
end

------------------------------------------------
-- Device Updates
------------------------------------------------
function updateDevice(lul_device, xmldata)
	lul_device = tonumber(lul_device)
	debug(string.format("updateDevice(%d,%s)",lul_device,xmldata or ""))

	if (xmldata == nil) or (xmldata == "unauthorized") then
		-- device is not up and running and reachable
		setVariableIfChanged(IPX800_SERVICE, "FirmwareVersion", xmldata or "", lul_device)
		setVariableIfChanged(IPX800_SERVICE, "Present", "0", lul_device)
		setVariableIfChanged(IPX800_SERVICE, "IconCode", "0", lul_device)
		-- if (xmldata == nil) then
			-- luup.set_failure(true,lul_device)	-- should be 1 in UI7
		-- else
			-- luup.set_failure(true,lul_device)	-- should be 2 in UI7
		-- end
	else
		local lomtab = lom.parse(xmldata)
		local ver = xpath.selectNodes(lomtab,"/response/version/text()")
		debug("ver:"..json.encode(ver))
		
		-- device is up and running and reachable
		setVariableIfChanged(IPX800_SERVICE, "FirmwareVersion", ver[1], lul_device)
		setVariableIfChanged(IPX800_SERVICE, "Present", "1", lul_device)
		setVariableIfChanged(IPX800_SERVICE, "IconCode", "100", lul_device)

		-- update MAC address
		local mac = xpath.selectNodes(lomtab,"/response/config_mac/text()")
		if (#mac>0) then	-- only present in new GlobalStatus.xml and not in old Status.xml
			setAttrIfChanged("mac", mac[1], lul_device)
		end
		
		luup.set_failure(false,lul_device)	-- should be 0 in UI7
		return lomtab
	end
	return nil
end

function updateVeraDeviceFromIpx(lul_device, name, ipxvalue, lomtab )
	lul_device = tonumber(lul_device)
	debug(string.format("updateVeraDeviceFromIpx(%d,%s,%s)",lul_device,name,ipxvalue))
	local ipxtype,ipxnum,veratype,options = getDeviceInformation(lul_device,name)
	
	if (ipxtype == "led") then
		-- It is an OUTPUT relay
		-- set the power value
		local v = tonumber(ipxvalue)
		if (veratype=="P") then
			IPXUpdatePowerTarget(lul_device,v,veratype)
		else
			debug(string.format("Ignoring update from name:%s because veratype is:%s",name,veratype))
			debug("options:"..json.encode(options))
		end
		
	elseif (ipxtype == "btn") then
		-- It is an INPUT relay
		-- set the power value
		local v=""
		if (ipxvalue=="up") then
			v=0
		else
			v=1
		end
		IPXUpdateInputButtonValue(lul_device,v,veratype)
		
	elseif (ipxtype == "ana") then
		-- It is an Analog input
		local anselect = xpath.selectNodes(lomtab,"/response/anselect"..ipxnum.."/text()")
		debug(string.format("name:%s anselect:%s",name,anselect[1]))
		local v = tonumber(ipxvalue)
		--0 and 9 => direct value
		if (anselect[1]=="1") then 
			v = v * 0.00323
		elseif (anselect[1]=="2") then 
			v = v * 0.323 - 50
		elseif (anselect[1]=="3") then 
			v = v * 0.09775
		elseif (anselect[1]=="4") then 
			v = v * 0.00323
			v = (v - 1.63) / 0.0326
		elseif (anselect[1]=="5") then 
			--TODO humidity sensor so needs add hTemp correction but we do not know 
			-- hTemp so let's take 15C as an average
			-- GetAn	HCTemp	0	10	20	30	40		Delta
			-- 0		0	0	0	0	0		
			-- 10		9,482268159	9,68054211	9,887284952	10,10305112	10,32844454		0,846176378
			-- 20		18,96453632	19,36108422	19,7745699	20,20610224	20,65688907		1,692352755
			-- 30		28,44680448	29,04162633	29,66185485	30,30915336	30,98533361		2,538529133
			-- 40		37,92907263	38,72216844	39,54913981	40,41220449	41,31377815		3,384705511
			v = v * 0.00323
			v = (v/3.3 - 0.1515) / 0.00636
			local HCtemp=15
			v = v/ (1.0546 - (0.00216 * HCtemp))
		elseif (anselect[1]=="6") then 
			v = (v * 0.00323 - 0.25) / 0.028
		elseif (anselect[1]=="7") then 
			v = v * 0.00323
		elseif (anselect[1]=="8") then 
			v = v * 0.00646
		elseif (anselect[1]=="9") then 
			v = v * 0.01615
		elseif (anselect[1]=="10") then 
			v = v /100
		elseif (anselect[1]=="11") then 
			v = v -2500
		end
		-- <select name="sel" id="select" style="width:186px;">Select Input:                     
        -- <option value="0" id="s0">Analog</option>                             
        -- <option value="1" id="s1">Volt</option>                             
        -- <option value="2" id="s2">TC4012 Sensor</option>
      	-- <option value="3" id="s3">SHT-X3:Light-LS100</option>    
      	-- <option value="4" id="s4">SHT-X3:Temp-TC5050</option>    
      	-- <option value="5" id="s5">SHT-X3:RH-SH100</option>
	    -- <option value="6" id="s6">TC100 Sensor</option> 
	    -- <option value="7" id="s7">X400 CT10A</option>
	    -- <option value="8" id="s8">X400 CT20A</option>
	    -- <option value="9" id="s9">X400 CT50A</option>
	    -- <option value="10" id="s10">X200 pH Probe</option>
	    -- <option value="11" id="s11">X200 ORP Probe</option>	
		-- </select>
		IPXUpdateSetAnalogValue(lul_device,v,veratype)
		--setCurrentTemperature(k,v)
	end
end

function updateChildrenDevices(lul_device, lomtab)
	lul_device = tonumber(lul_device)
	debug(string.format("updateChildrenDevices(%d)",lul_device))
	
	-- for all children device, iterate
	local param = {}
	for k,v in pairs(luup.devices) do
		if( getParent(k)==lul_device) then
			-- find the altid
			local name = v.id
			debug(string.format("device altid=%s",name))
			-- find the xml node with the same name
			-- read the value 
			local led = xpath.selectNodes(lomtab,"/response/"..name.."/text()")
			debug(string.format("tag=%s value=%s",name, led[1]))
			updateVeraDeviceFromIpx( k, name, led[1] , lomtab )
		end
	end
end

------------------------------------------------
-- LOOPING Engine
------------------------------------------------
function refreshDevice(lul_device,norepeat)
	lul_device = tonumber(lul_device)
	debug(string.format("refreshDevice(%d,%s)",lul_device, tostring(norepeat or "")))
	--luup.attr_get(name, deviceId)
	local updateFrequencySec= tonumber( getSetVariable(IPX800_SERVICE,"UpdateFrequency", lul_device, 60) or 60 )
		
	--http://ipx800_v3/globalstatus.xml
	local xmldata = ipx800HttpCall(lul_device,"globalstatus.xml")
	-- fallback for old cards
	if (xmldata==nil) then	
		xmldata = ipx800HttpCall(lul_device,"status.xml")	-- old cards
	end
	-- updates device & children
	local lomtab = updateDevice(lul_device, xmldata)
	if (lomtab~=nil) then
		updateChildrenDevices(lul_device, lomtab)
	end
	-- repeat every x seconds
	if (updateFrequencySec>0) and (norepeat~=true) then 
		debug(string.format("Programming the next refresh in %d seconds",updateFrequencySec))
		luup.call_timer("refreshDevice",1,updateFrequencySec,"",lul_device)
	end
	if (lomtab~=nil) then
		return true
	end	
	warning(string.format("refreshDevice(%d,%s) did not succeed",lul_device, tostring(norepeat or "")))
	return false
end

------------------------------------------------
-- STARTUP Sequence
------------------------------------------------
function updateChildDevicesNames(lul_device)
	lul_device = tonumber(lul_device)
	debug(string.format("updateChildDevicesNames(%d)",lul_device))
	local outputRelays = getSetVariable(IPX800_SERVICE,"OutputRelays", lul_device, "") or ""
	local inputRelays = getSetVariable(IPX800_SERVICE,"InputRelays", lul_device, "") or ""
	local analogInputs= getSetVariable(IPX800_SERVICE,"AnalogInputs", lul_device, "") or ""
	
	--- try http://192.168.1.10/ioname.xml
	local xmldata = ipx800HttpCall(lul_device,"ioname.xml")
	if (xmldata==nil) or (xmldata=="unauthorized") then
		--
		-- fallback method, do it line by line by spying html pages
		--
		debug("No ioname.xml page available, proceeding with fallback plan")
		for k,v in pairs(Split(outputRelays,",")) do
			-- set the name, relay number is name:sub(4)
			local idx,typ =  string.match(v,outputRelaysPattern)
			local devicename = getIpxRelayName(lul_device,idx-1)
			local childdevice = findChild( lul_device, "led"..(idx-1) )
			setAttrIfChanged("name", "IPX "..devicename, childdevice)
		end
		for k,v in pairs(Split(inputRelays,",")) do
			-- set the name, relay number is name:sub(4)
			local idx,typ =  string.match(v,inputRelaysPattern)
			local devicename = getIpxInputName(lul_device,idx-1)
			local childdevice = findChild( lul_device, "btn"..(idx-1) )
			setAttrIfChanged("name", "IPX "..devicename, childdevice)
		end	
		for k,v in pairs(Split(analogInputs,",")) do
			-- set the name, relay number is name:sub(4)
			local idx,typ = string.match(v,analogInputPattern)
			local devicename = getIpxAnalogName(lul_device,idx-1)
			local childdevice = findChild( lul_device, "analog"..(idx-1) )
			setAttrIfChanged("name", "IPX "..devicename, childdevice)
		end
	else
		debug("ioname.xml page available...")
		local lomtab = lom.parse(xmldata)
		local ver = xpath.selectNodes(lomtab,"/response/version/text()")
		for k,v in pairs(Split(outputRelays,",")) do
			-- set the name, relay number is name:sub(4)
			local idx,typ =  string.match(v,outputRelaysPattern)
			local devicename =xpath.selectNodes(lomtab,"/response/output"..idx.."/text()")
			local childdevice = findChild( lul_device, "led"..(idx-1) )
			setAttrIfChanged("name", "IPX "..devicename[1], childdevice)
		end
		for k,v in pairs(Split(inputRelays,",")) do
			-- set the name, relay number is name:sub(4)
			local idx,typ =  string.match(v,inputRelaysPattern)
			local devicename =xpath.selectNodes(lomtab,"/response/input"..idx.."/text()")
			local childdevice = findChild( lul_device, "btn"..(idx-1) )
			setAttrIfChanged("name", "IPX "..devicename[1], childdevice)
		end	
		for k,v in pairs(Split(analogInputs,",")) do
			-- set the name, relay number is name:sub(4)
			local idx,typ = string.match(v,analogInputPattern)
			local devicename =xpath.selectNodes(lomtab,"/response/analog"..idx.."/text()")
			local childdevice = findChild( lul_device, "analog"..(idx-1) )
			setAttrIfChanged("name", "IPX "..devicename[1], childdevice)
		end
	end
end

function createChildDevices(lul_device)
	lul_device = tonumber(lul_device)
	debug("createChildDevices, called on behalf of device:"..lul_device)
	local outputRelays = getSetVariable(IPX800_SERVICE,"OutputRelays", lul_device, "") or ""
	local inputRelays = getSetVariable(IPX800_SERVICE,"InputRelays", lul_device, "") or ""
	local analogInputs= getSetVariable(IPX800_SERVICE,"AnalogInputs", lul_device, "") or ""

	-- for now , just test with one device
    local child_devices = luup.chdev.start(lul_device);
	
	-- create output relay devices
	debug("outputRelays:"..outputRelays)
	for k,v in pairs(Split(outputRelays,",")) do
		local i,t = string.match(v,outputRelaysPattern)	-- device & type P by default or W
		i = tonumber(i)
		if (t==nil) or (t=="") then
			t="P"
		else
			-- t = W-2-3-30
			local tbl = Split(t,"-")
			t= tbl[1]
		end
		if (i>=1) and (i<=32) then
			debug(string.format("Creating device for output relay:%d",i))
			local devtype = mapCodeToDeviceType[t].DType or "urn:schemas-upnp-org:device:BinaryLight:1"
			local devfile = mapCodeToDeviceType[t].DFile or "D_BinaryLight1.xml"
			debug(string.format("Creating device for output:%d, type:%s devtype:%s devfile:%s",i,t,devtype,devfile))
			luup.chdev.append(
				lul_device, child_devices, 
				"led"..(i-1), "IPX800 Out "..i, 
				devtype,devfile,  
				"", "", 
				false		-- embedded
				)
		end
	end

	-- create analog input  devices
	debug("analogInputs:"..analogInputs)
	for k,v in pairs(Split(analogInputs,",")) do
		local i,t = string.match(v,analogInputPattern)	-- device & type T, L , H
		i = tonumber(i)
		if (t==nil) or (t=="") then
			t="T"
		end
		if (i>=1) and (i<=16) then
			debug(string.format("Creating device for analog input:%d",i))
			local devtype = mapCodeToDeviceType[t].DType or "urn:schemas-micasaverde-com:device:TemperatureSensor:1"
			local devfile = mapCodeToDeviceType[t].DFile or "D_TemperatureSensor1.xml"
			debug(string.format("Creating device for analog input:%d, type:%s devtype:%s devfile:%s",i,t,devtype,devfile))
			luup.chdev.append(
				lul_device, child_devices, 
				"analog"..(i-1), "IPX800 Analog "..i, 
				devtype,devfile,  
				"", "", 
				false		-- embedded
				)
		end
	end
	
	-- create input relay devices
	debug("inputRelays:"..inputRelays)	
	for k,v in pairs(Split(inputRelays,",")) do
		local i,t = string.match(v,inputRelaysPattern)	-- device & type P:powerswitch M:motionsensor D:doorlock
		i = tonumber(i)
		if (t==nil) or (t=="") then
			t="P"
		end
		if (i>=1) and (i<=32) then
			local devtype = mapCodeToDeviceType[t].DType or "urn:schemas-upnp-org:device:BinaryLight:1"
			local devfile = mapCodeToDeviceType[t].DFile or "D_BinaryLight1.xml"
			debug(string.format("Creating device for digital input:%d, type:%s devtype:%s devfile:%s",i,t,devtype,devfile))
			luup.chdev.append(
				lul_device, child_devices, 
				"btn"..(i-1), "IPX800 In "..i, 
				devtype,devfile, "", 
				string.format("%s,Inverted=0",IPX800_SERVICE), 
				false		-- embedded
				)
		end
	end

    luup.chdev.sync(lul_device, child_devices)
end

function startupDeferred(lul_device)
	lul_device = tonumber(lul_device)
	log("startupDeferred, called on behalf of device:"..lul_device)
		
	setAttrIfChanged("manufacturer", "GCE Electronic", lul_device)
	setAttrIfChanged("model", "IPX800 v3", lul_device)
	local debugmode = getSetVariable(IPX800_SERVICE, "Debug", lul_device, "0")
	local oldversion = getSetVariable(IPX800_SERVICE, "Version", lul_device, version)
	local present = getSetVariable(IPX800_SERVICE,"Present", lul_device, 0)
	local iconCode = getSetVariable(IPX800_SERVICE,"IconCode", lul_device, 0)
	local ipxIpAddress = getSetVariable(IPX800_SERVICE,"IpxIpAddress", lul_device, "ipx800_v3")
	setAttrIfChanged("ip", ipxIpAddress, lul_device)
	local firmwareVersion= getSetVariable(IPX800_SERVICE,"FirmwareVersion", lul_device, "")
	local user= getSetVariable(IPX800_SERVICE,"User", lul_device, "")
	local password= getSetVariable(IPX800_SERVICE,"Password", lul_device, "")
	setAttrIfChanged("user", user, lul_device)
	setAttrIfChanged("pass", password, lul_device)
	local updateFrequencySec= getSetVariable(IPX800_SERVICE,"UpdateFrequency", lul_device, 60)
	local outputRelays= getSetVariable(IPX800_SERVICE,"OutputRelays", lul_device, "")
	local inputRelays= getSetVariable(IPX800_SERVICE,"InputRelays", lul_device, "")
	local analogInputs= getSetVariable(IPX800_SERVICE,"AnalogInputs", lul_device, "")

	if (debugmode=="1") then
		DEBUG_MODE = true
		UserMessage("Enabling debug mode as Debug variable is set to 1 for device:"..lul_device,TASK_BUSY)
	end
	
	local major,minor = 0,0
	if (oldversion~=nil) then
		major,minor = string.match(oldversion,"v(%d+)%.(%d+)")
		major,minor = tonumber(major),tonumber(minor)
		debug ("Plugin version: "..version.." Device's Version is major:"..major.." minor:"..minor)
		luup.variable_set(IPX800_SERVICE, "Version", version, lul_device)
	end

	---------------------------------------------------------------------------------------
	-- ONLY if this is the parent/root device we create child and start the refresh engine
	-- otherwise, we are a child device and we are a slave, nothing to do
	---------------------------------------------------------------------------------------
	if (getParent(lul_device)==0) then
		-- create child device
		log("startup completed for root device, called on behalf of device:"..lul_device)
	else
		log("startup completed for child device, called on behalf of device:"..lul_device)
	end
	
	createChildDevices(lul_device)
	
	-- start refreshes , with repeat
	refreshDevice(lul_device,false)
end
		
function initstatus(lul_device)
	lul_device = tonumber(lul_device)
	log("initstatus("..lul_device..") starting version: "..version)
	checkVersion()
	
	local delay = math.random(RAND_DELAY)	-- delaying first refresh by x seconds
	if (getParent(lul_device)==0) then
		debug("initstatus("..lul_device..") startup for Root device, delay:"..delay)
	else
		debug("initstatus("..lul_device..") startup for Child device, delay:"..delay)
	end
	-- http://192.168.1.5:3480/data_request?id=lr_IPX800_Handler
	luup.register_handler("myIPX800_Handler","IPX800_Handler")
	luup.call_delay("startupDeferred", delay, tostring(lul_device))		
end

 
-- do not delete, last line must be a CR according to MCV wiki page

 
