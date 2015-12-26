package tink.http;

import tink.io.Source;

class Message<H:Header, B:Source> {
  
  public var header(default, null):H;
  public var body(default, null):B;
  
  public function new(header, body) {
    this.header = header;
    this.body = body;
  }
    
}