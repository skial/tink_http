package tink.http.containers.aws;

import tink.core.Any;
import tink.core.Signal;
import tink.core.Future;
import tink.http.Header;
import tink.http.Method;
import tink.http.Request;
import tink.http.Handler;
import haxe.DynamicAccess;
import tink.http.Container;

using StringTools;
using tink.CoreApi;


private typedef NodeContext = {
	var succeed:String->Void;
	var fail:String->Void;
	var done:Void->Void;
	var getRemainingTimeInMillis:Void->Int;
	var functionName:String;
	var functionVersion:String;
	var invokedFunctionArn:String;
	var memoryLimitInMB:String;
	var awsRequestId:String;
	var logGroupName:String;
	var logStreamName:String;
}

private typedef RequestInfo = {
	var ip:String;
	var body:String;
	var method:String;
	var resourcePath:String;
	var query:DynamicAccess<String>;
	var params:DynamicAccess<String>;
	var headers:DynamicAccess<String>;
}

private typedef LambdaInfo = {
	var event:RequestInfo;
	var context:NodeContext;
}

class NodeContainer implements Container {
	
	private static var trigger:FutureTrigger<LambdaInfo> = Future.trigger();
	private static var lambdaRequest:Future<LambdaInfo> = trigger.asFuture();
	
	@:expose('handler')
	public static function lambdaHandler(event:RequestInfo, context:NodeContext):Void {
		trace(event, context);
		trigger.trigger({event:event, context:context});
	}
	
	public function new() {
		trace('creating aws lambda container');
	}
	
	public function run(handler:Handler):Future<ContainerResult> {
		return Future.async(function(cb) {
			lambdaRequest.handle(function(data) {
				trace( 'running', data );
				
				var uriParts = data.event.resourcePath.split('/');
				for (i in 0...uriParts.length) {
					if (uriParts[i].startsWith('{')) {
						var da:DynamicAccess<String> = data.event.params;
						var key = uriParts[i].substring(1, uriParts[i].length - 1);
						trace( uriParts, uriParts[i], da.keys(), key, da.exists( key ), da.get( key ) );
						
						if ( da.exists( key ) ) {
							uriParts[i] = da.get( key );
							
						}
					
					}
					
				}
				
				handler.process(
					new IncomingRequest(
						data.event.ip, 
						new IncomingRequestHeader(
							Method.ofString( data.event.method, function(_) return GET ), // Http Method.
							uriParts.join('/'), // Requested Path.
							'1.1', // Assumed value, not sure how to work it out from available aws lambda & gateway info.
							[for (key in data.event.headers.keys()) new HeaderField(key, data.event.headers.get( key ))]	// Mapped headers
						), 
						Plain(data.event.body)
					)
					
				).handle(function(response) {
					response.body.all().handle(function(value) switch value {
						case Success(body):
							var json = haxe.Json.stringify({
								code:response.header.statusCode,
								reason:response.header.reason,
								headers: [for (h in response.header.fields) h.toString()],
								body: body.toString(),
							});
							trace( json );
							data.context.succeed(json);

						case Failure(error):
							trace( error.toString() );
							data.context.fail(error.toString());
							
					});
					
				});
				
			});
			
		});
		
	}
	
}
