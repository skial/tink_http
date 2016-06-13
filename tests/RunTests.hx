package;

import haxe.PosInfos;
import haxe.io.StringInput;
import sys.io.Process;
import tink.core.Future;
import tink.core.Noise;
import tink.http.Container;
import tink.http.Client;
import tink.http.Header.HeaderField;
import tink.http.Method;
import tink.http.Multipart;
import tink.http.Request;
import tink.http.containers.*;
import tink.io.IdealSource;
import tink.url.Host;
import DummyServer;

using tink.CoreApi;

class RunTests {
  static function assertEquals<A>(expected:A, found:A, ?pos) 
    if (expected != found)
      throw Error.withData('expected $expected but found $found', [expected, found], pos);
  
  static function performTest(host:Host, clients:Array<Client>):Future<Noise> {    
    var ret = [];
    
    for (c in clients) {
      function roundtrip(method:Method, uri:String = '/', ?fields:Array<HeaderField>, body:String = '') {
        ret.push(Future.async(function (cb) {
          
          fields = switch fields {
            case null: [];
            case v: v.copy();
          }
          
          var req = new OutgoingRequest(new OutgoingRequestHeader(method, host, uri, fields), body);
          switch body.length {
            case 0:
            case v: 
              switch req.header.get('content-length') {
                case []:
                  fields.push(new HeaderField('content-length', Std.string(v)));
                default:
              }
          }
          c.request(req).handle(function (res) {
            res.body.all().handle(function (o) {
              var raw = o.sure().toString();
              trace(raw);
			  var data:Data = haxe.Json.parse(raw);
              assertEquals((method:String), data.method);
              assertEquals(uri, data.uri);
              assertEquals(body, data.body);
              cb(Noise);
            });
          });
        }));
      }
        
      roundtrip(GET);
      roundtrip(GET, '/?foo=bar&foo=2');
      roundtrip(POST, '/', 'hello there!');
    }
    
    return Future.ofMany(ret).map(function (_) return Noise);
  }
  
  static function onContainer(c:Container, f:Void->Future<Noise>) 
    return Future.async(function (cb) {
      c.run(DummyServer.handleRequest).handle(function (r) switch r {
        case Running(server):
          f().handle(function () server.shutdown(true).handle(function () cb(Noise)));
        case v: 
          throw 'unexpected $v';
      });
    });
  
  static function onServer(f:Host->Future<Noise>) {
    var ret = [];
	
    #if php
	
    if (new Process('haxe', ['build-php.hxml']).exitCode() != 0)
      throw 'failed to build PHP';
    var server = new Process('php', ['-S', '127.0.0.1:8000', 'testphp/index.php']);
    waitForConnection('127.0.0.1', 8000);
    var done = f(new Host('127.0.0.1', 8000));
    var h = new haxe.Http('http://127.0.0.1:8000/multipart');
    var s = 'hello world';
    
    h.fileTransfer('test', 'test.txt', new StringInput(s), s.length, "text/plain");
    h.setParameter('foo', 'bar');
    h.onError = function (error) throw error;
    h.onData = function (data) {
      var data:Data = haxe.Json.parse(data);
      var a:Array<{ name:String }> = haxe.Json.parse(data.body);
      var map = [for (x in a) x.name => true];
      assertEquals(map['test'], true);
      assertEquals(map['foo'], true);
    };
    
    h.request(true);
    
    ret.push(done);
    done.handle(function () {
      server.kill();
    });
	
    #elseif (neko && (nekotools || mod_neko))
	
    Sys.command('haxe', ['build-neko.hxml']);
    var cwd = Sys.getCwd();
    Sys.setCwd('testneko');
	#if nekotools
    var server = new Process('nekotools', ['server', '-p', '8000', '-rewrite']);
	waitForConnection('0.0.0.0', 8000);
	#elseif mod_neko
	sys.io.File.saveContent('.htaccess', ['RewriteEngine On','RewriteBase /','RewriteRule ^(.*)$ index.n [QSA,L]'].join('\n'));
	Sys.command('docker', ['run', '-d', '-v', sys.FileSystem.fullPath(Sys.getCwd())+':/var/www/html', '-p', '8000:80', '--name', 'tink_http_mod_neko', 'codeurs/mod-neko']);
	waitForConnection('0.0.0.0', 8000);
	Sys.sleep(2);
	#end
    Sys.setCwd(cwd);
	function kill() {
	  #if mod_neko
	  Sys.command('docker', ['stop', 'tink_http_mod_neko']);
	  Sys.command('docker', ['rm', 'tink_http_mod_neko']);
	  #else
      server.kill();
	  #end
	}
	
	try {
	  var done = f(new Host('0.0.0.0', 8000));
	  ret.push(done);
	  done.handle(kill);
	} catch (e: Dynamic) {
	  Sys.println('Failed: '+e);
	  kill();
	}
    
    #elseif (neko || java || cpp)
	
    ret.push(onContainer(new TcpContainer(2000), f.bind(new Host('localhost', 2000))));
	
    #elseif nodejs
	
    ret.push(onContainer(new NodeContainer(3000), f.bind(new Host('localhost', 3000))));
	
    #end
	
    return Future.ofMany(ret);
  }
  
  #if sys
  static function waitForConnection(host, port) {
	var i = 0;
    while (i < 100) {
      try {
        var socket = new sys.net.Socket();
        socket.connect(new sys.net.Host(host), port);
        socket.close();
        break;
      } catch(e: Dynamic) {
        Sys.sleep(.1);
        i++;
      }
    }
  }
  #end
  
  static function getClients() {
    var clients:Array<Client> = [];
    
    #if (php || (neko && (nekotools || mod_neko)))
      clients.push(new StdClient());
    #elseif (neko || java || cpp)
      clients.push(new TcpClient());
    #elseif nodejs
      clients.push(new NodeClient());
    #end
	
    return clients;
  }
  
  static function main() {
    onServer(performTest.bind(_, getClients())).handle(function () {
      Sys.exit(0);//Just in case
    });
  }
  
}