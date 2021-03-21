//# sourceURL=J_IPX800.js
//-------------------------------------------------------------
// IPX 800 Plugin javascript Tabs
//-------------------------------------------------------------
var ipx800_Svs = 'urn:upnp-org:serviceId:IPX8001';
var ip_address = data_request_url;

var IPX800_Utils = (function(){
	//-------------------------------------------------------------
	// Utilities Javascript
	//-------------------------------------------------------------
	function isFunction(x) {
	  return Object.prototype.toString.call(x) == '[object Function]';
	};

	//-------------------------------------------------------------
	// Pattern Matching functions
	//-------------------------------------------------------------	
	function goodip(ip)
	{
		// @duiffie contribution
		var reg = new RegExp('^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(:\\d{1,5})?$', 'i');
		return(reg.test(ip));
	};
	function goodint(v)
	{
		var reg = new RegExp('^[0-9]+$', 'i');
		return(reg.test(v));
	};
	function goodcsv(v)
	{
		var reg = new RegExp('^[0-9]*(,[0-9]+)*$', 'i');
		return(reg.test(v));
	};
	function goodcsvoutput(v)
	{
		// ex: 1W-2-3-20,2,3W-2-3-40,3W-2-3-40
		var reg =  /^(\d+(W-\d+-\d+(-\d+)*|P)?)+(,\d+(W-\d+-\d+(-\d+)*|P)?)*$/; 
		return(reg.test(v));
	};
	function goodcsvinput(v)
	{
		var reg = new RegExp('^[0-9]*[PDM]?(,[0-9]+[PDM]?)*$', 'i');
		return(reg.test(v));
	};
	function goodcsvanalog(v)
	{
		var reg = new RegExp('^[0-9]*[TL]?(,[0-9]+[TLH]?)*$', 'i');
		return(reg.test(v));
	};
	//-------------------------------------------------------------
	// Helper functions to build URLs to call VERA code from JS
	//-------------------------------------------------------------
	function buildVariableSetUrl( deviceID, service, varName, varValue)
	{
		var urlHead = '' + ip_address + 'id=variableset&DeviceNum='+deviceID+'&serviceId='+service+'&Variable='+varName+'&Value='+varValue;
		return urlHead;
	};

	function buildUPnPActionUrl(deviceID,service,action)
	{
		var urlHead = ip_address +'id=action&output_format=json&DeviceNum='+deviceID+'&serviceId='+service+'&action='+action;//'&newTargetValue=1';
		return urlHead;
	};

	//-------------------------------------------------------------
	// Variable saving ( log , then full save )
	//-------------------------------------------------------------
	function saveVar(deviceID,  service, varName, varVal)
	{
		if (typeof(g_ALTUI)=="undefined") {
			//Vera
			if (api != undefined ) {
				api.setDeviceState(deviceID, service, varName, varVal,{dynamic:false})
				api.setDeviceState(deviceID, service, varName, varVal,{dynamic:true})
			}
			else {
				set_device_state(deviceID, service, varName, varVal, 0);
				set_device_state(deviceID, service, varName, varVal, 1);
			}
			var url = IPX800_Utils.buildVariableSetUrl( deviceID, service, varName, varVal)
			jQuery.get( url )
				.done(function(data) {
				})
				.fail(function() {
					alert( "Save Variable failed" );
				})
		} else {
			//Altui
			set_device_state(deviceID, service, varName, varVal);
		}
	};
	
	function validateAndSave(deviceID, varName, varVal, func, reload) {
		// reload is optional parameter and defaulted to false
		if (typeof reload === "undefined" || reload === null) { 
			reload = false; 
		}

		if ((!func) || func(varVal)) {
			//set_device_state(deviceID,  ipx800_Svs, varName, varVal);
			IPX800_Utils.saveVar(deviceID,  ipx800_Svs, varName, varVal, reload)
			jQuery('#ipx800_' + varName).css('color', 'black');
		} else {
			jQuery('#ipx800_' + varName).css('color', 'red');
			alert(varName+':'+varVal+' is not correct');
		}
	};

	return {
		isFunction:isFunction,
		goodip:goodip,
		goodint:goodint,
		goodcsv:goodcsv,
		goodcsvoutput:goodcsvoutput,
		goodcsvinput:goodcsvinput,
		goodcsvanalog:goodcsvanalog,
		buildVariableSetUrl:buildVariableSetUrl,
		buildUPnPActionUrl:buildUPnPActionUrl,
		saveVar:saveVar,
		validateAndSave:validateAndSave
	}
})();




//-------------------------------------------------------------
// Device TAB : Settings
//-------------------------------------------------------------	
function ipx800_Donate(deviceID) {
	var htmlDonate='For those who really like this plugin and feel like it, you can donate what you want here on Paypal. It will not buy you more support not any garantee that this can be maintained or evolve in the future but if you want to show you are happy and would like my kids to transform some of the time I steal from them into some <i>concrete</i> returns, please feel very free ( and absolutely not forced to ) to donate whatever you want.  thank you ! ';
	htmlDonate += '<form action="https://www.paypal.com/cgi-bin/webscr" method="post" target="_top"><input type="hidden" name="cmd" value="_s-xclick"><input type="hidden" name="encrypted" value="-----BEGIN PKCS7-----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-----END PKCS7-----"><input type="image" src="https://www.paypalobjects.com/en_US/FR/i/btn/btn_donateCC_LG.gif" border="0" name="submit" alt="PayPal - The safer, easier way to pay online!"><img alt="" border="0" src="https://www.paypalobjects.com/fr_FR/i/scr/pixel.gif" width="1" height="1"></form>';
	var html = '<div>'+htmlDonate+'</div>';
	set_panel_html(html);
}

//-------------------------------------------------------------
// Device TAB : Settings
//-------------------------------------------------------------	
function ipx800_Settings(deviceID) {
	// first determine if it is a child device or not
	//var device = IPX800_Utils.findDeviceIdx(deviceID);
	//var debug  = get_device_state(deviceID,  ipx800_Svs, 'Debug',1);
	//var root = (device!=null) && (jsonp.ud.devices[device].id_parent==0);
    var version  = get_device_state(deviceID,  ipx800_Svs, 'Version',"00");
    var present  = get_device_state(deviceID,  ipx800_Svs, 'Present',1);
	var ipaddr = get_device_state(deviceID,  ipx800_Svs, 'IpxIpAddress',1);
	var updatefrequency = get_device_state(deviceID,  ipx800_Svs, 'UpdateFrequency',1);
	var outputRelays = get_device_state(deviceID,  ipx800_Svs, 'OutputRelays',1);
	var inputRelays = get_device_state(deviceID,  ipx800_Svs, 'InputRelays',1);
	var analogInputs = get_device_state(deviceID,  ipx800_Svs, 'AnalogInputs',1);
	
	var htmlopenipx = '<button class="btn btn-default" id="ipx800_OpenWeb" type="button">Configure</button>';
	var htmlipaddr = 'IPX ip(:port) :</td><td><input id="ipx800_IpxIpAddress" type="text" size="15" value="'+ipaddr+'" onchange="ipx_SetIpAddress(' + deviceID + ', \'IpxIpAddress\', this.value);"> <button class="btn btn-default" id="ipx800_TestRefresh">Test</button>'+htmlopenipx;
	var htmlrefresh = 'Update Frequency:</td><td><input id="updatefrequency" size="5" min="0" max="9999" type="number" value="'+updatefrequency+'" onchange="ipx_SetUpdateFrequency(' + deviceID + ', \'UpdateFrequency\', this.value)"> seconds.';
	var htmlpushmsg = 'you can also configure a PUSH from the ipx800 with the following path: /data_request?id=lr_IPX800_Handler&mac=$M&deviceID='+deviceID;
	var htmloutput = 'Show Output Relays:</td><td><input id="ipx800_OutputRelays" type="text" size="15" value="'+outputRelays+'" onchange="ipx_SetOutputRelays(' + deviceID + ', \'OutputRelays\', this.value);">'+' csv list of numbers (1..32) & optional type W for window cover.ex: 1,5,6 or 1W-2-3-30-40,5,6 for up,"W","-",stop,"-",down,"-",up time,"-",down time (in sec). Relays must be configured in pulse mode for window cover.';
	var htmlinput = 'Show Digital Input:</td><td><input id="ipx800_InputRelays" type="text" size="15" value="'+inputRelays+'" onchange="ipx_SetInputRelays(' + deviceID + ', \'InputRelays\', this.value);">'+' csv list of numbers & optional type : 1,2 or 1P,2M';
	var htmlanainput = 'Show Analog Inputs:</td><td><input id="ipx800_AnalogInputs" type="text" size="15" value="'+analogInputs+'" onchange="ipx_SetAnalogInputs(' + deviceID + ', \'AnalogInputs\', this.value);">'+' csv list of numbers & optional type TLH : 1,2 or 1T,2L';
	var htmlrefreshnames = 'Special actions:</td><td><button class="btn btn-default" id="ipx800_IpxNames" type="button">Get IPX Names</button>';

	var style='	<style>\
	  table#ipx800_table td:first-child{\
		background-color: #E0E0E0;\
		width: 140px;\
	  }\
	</style>';
	var html =
		style+
		'<div class="pane" id="pane"> '+ 
		'<table class="table" id="ipx800_table">'+
		'<tr><td>'+htmlipaddr+'</td></tr>' +
		'<tr><td>'+htmlrefresh+'</td></tr>' +
		'<tr><td></td><td>'+htmlpushmsg+'</td></tr>' +
		'<tr><td>'+htmloutput+'</td></tr>' +
		'<tr><td>'+htmlinput+'</td></tr>' +
		'<tr><td>'+htmlanainput+'</td></tr>' +
		'<tr><td>'+htmlrefreshnames+'</td></tr>' +
		'</table>'+
		'</div>'+
		'<span style="float:right;">'+version+'</span>'
		;

	//html = html + '<button id="button_save" type="button">Save</button>'
	set_panel_html(html);

	// click  handler to get pattern value and add it to target names 
	jQuery( "#ipx800_OpenWeb" ).click(function() {
		ipaddr = get_device_state(deviceID,  ipx800_Svs, 'IpxIpAddress',1);
		var url = "http://"+ipaddr;
		window.open(url);
	});
	jQuery( "#ipx800_IpxNames" ).click(function() {
		var url = IPX800_Utils.buildUPnPActionUrl(deviceID,ipx800_Svs,"IPXNames");
		jQuery.get( url );
	});
	jQuery( "#ipx800_TestRefresh" ).click(function() {
		var url = IPX800_Utils.buildUPnPActionUrl(deviceID,ipx800_Svs,"Refresh");
		jQuery.get( url ,function( data ) {
			//alert("Success:"+data);
		})
		.fail(function() {
			alert("Internal failure, could not run the VERA action");
		});
	});
}

//-------------------------------------------------------------
// Save functions
//-------------------------------------------------------------	

function ipx_SetIpAddress(deviceID, varName, varVal) {
	return IPX800_Utils.validateAndSave(deviceID, varName, varVal, IPX800_Utils.goodip);
}
function ipx_SetOutputRelays(deviceID, varName, varVal) {
	return IPX800_Utils.validateAndSave(deviceID, varName, varVal.trim(), IPX800_Utils.goodcsvoutput, true);
}
function ipx_SetInputRelays(deviceID, varName, varVal) {
	return IPX800_Utils.validateAndSave(deviceID, varName, varVal.trim(), IPX800_Utils.goodcsvinput, true);
}
function ipx_SetAnalogInputs(deviceID, varName, varVal) {
	return IPX800_Utils.validateAndSave(deviceID, varName, varVal.trim(), IPX800_Utils.goodcsvanalog, true);
}
function ipx_SetUpdateFrequency(deviceID, varName, varVal) {
	return IPX800_Utils.validateAndSave(deviceID, varName, varVal, IPX800_Utils.goodint);
}







