unit IdGeminiServer;

interface

uses
  SysUtils, Classes, IdTCPServer, IdContext, IdGlobal, IdSSL, 
  IdServerIOHandlerSSLOpenSSL, IdSSLOpenSSL, IdURI, IdIDN;

type
  TGeminiStatus = (gsUnknown, gsInput, gsSensitiveInput, gsSuccess, 
    gsRedirectTemporary, gsRedirectPermanent, gsTempFailure, gsPermFailure, 
    gsCertRequired, gsCertNotAuthorized, gsCertNotValid);

  TGeminiRequestEvent = procedure(AContext: TIdContext; const AURL: string;
    out Status: TGeminiStatus; out Meta: string; out Response: TStream) of object;

  TIdGeminiServer = class(TIdTCPServer)
  private
    FOnGeminiRequest: TGeminiRequestEvent;
    FSSLIOHandler: TIdServerIOHandlerSSLOpenSSL;
    procedure InternalExecute(AContext: TIdContext);
    function StatusToCode(Status: TGeminiStatus): string;
  protected
    procedure InitComponent; override;
  public
    destructor Destroy; override;
    class procedure WriteStringToStream(Stream: TStream; const S: string; Encoding: TEncoding = nil);
    property SSLIOHandler: TIdServerIOHandlerSSLOpenSSL read FSSLIOHandler;
  published
    property OnGeminiRequest: TGeminiRequestEvent read FOnGeminiRequest write FOnGeminiRequest;
    property DefaultPort default 1965;
  end;

implementation

{ TIdGeminiServer }

procedure TIdGeminiServer.InitComponent;
begin
  inherited InitComponent;
  DefaultPort := 1965;
  OnExecute := InternalExecute;
  
  // Create and configure SSL/TLS handler
  FSSLIOHandler := TIdServerIOHandlerSSLOpenSSL.Create(Self);
  FSSLIOHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLIOHandler.SSLOptions.Mode := sslmServer;
  IOHandler := FSSLIOHandler;
  
  InitIDNLibrary;
end;

destructor TIdGeminiServer.Destroy;
begin
  inherited Destroy;
end;

function TIdGeminiServer.StatusToCode(Status: TGeminiStatus): string;
begin
  case Status of
    gsInput:                Result := '10';
    gsSensitiveInput:       Result := '11';
    gsSuccess:              Result := '20';
    gsRedirectTemporary:    Result := '30';
    gsRedirectPermanent:    Result := '31';
    gsTempFailure:          Result := '40';
    gsPermFailure:          Result := '50';
    gsCertRequired:         Result := '60';
    gsCertNotAuthorized:    Result := '61';
    gsCertNotValid:         Result := '62';
  else
    Result := '50'; // Unknown status defaults to server error
  end;
end;

class procedure TIdGeminiServer.WriteStringToStream(Stream: TStream; const S: string; Encoding: TEncoding);
var
  Bytes: TBytes;
begin
  if Encoding = nil then
    Encoding := TEncoding.UTF8;

  Bytes := Encoding.GetBytes(S);
  if Length(Bytes) > 0 then
    Stream.WriteBuffer(Bytes[0], Length(Bytes));
end;

procedure TIdGeminiServer.InternalExecute(AContext: TIdContext);
var
  RequestURL: string;
  ResponseStream: TMemoryStream;
  Status: TGeminiStatus;
  Meta: string;
  StatusCode: string;
  LURI: TIdURI;
begin
  ResponseStream := nil;
  LURI := nil;

  try
    // Read request line (URL + CRLF)
    RequestURL := AContext.Connection.IOHandler.ReadLn;
    
    // Validate request
    if RequestURL = '' then
    begin
      AContext.Connection.IOHandler.WriteLn('59 Empty request');
      Exit;
    end;

    // Check URL length (max 1024 bytes per spec)
    if Length(RequestURL) > 1024 then
    begin
      AContext.Connection.IOHandler.WriteLn('59 URL too long');
      Exit;
    end;

    // Parse and validate URL
    try
      LURI := TIdURI.Create(RequestURL);
      
      // Reject requests with userinfo
      if LURI.Username <> '' then
      begin
        AContext.Connection.IOHandler.WriteLn('59 Userinfo not allowed');
        Exit;
      end;

      // Reject requests with fragments
      if LURI.Document <> '' then
      begin
        AContext.Connection.IOHandler.WriteLn('59 Fragments not allowed');
        Exit;
      end;
    except
      on E: Exception do
      begin
        AContext.Connection.IOHandler.WriteLn('59 Invalid URL format');
        Exit;
      end;
    end;

    // Prepare response
    Status := gsPermFailure;
    Meta := 'No handler configured';
    ResponseStream := TMemoryStream.Create;

    // Call event handler
    if Assigned(FOnGeminiRequest) then
      FOnGeminiRequest(AContext, RequestURL, Status, Meta, ResponseStream);

    // Convert status to status code
    StatusCode := StatusToCode(Status);

    // Send response header
    AContext.Connection.IOHandler.WriteLn(StatusCode + ' ' + Meta);

    // Send response body for successful requests
    if Status = gsSuccess then
    begin
      ResponseStream.Position := 0;
      AContext.Connection.IOHandler.Write(ResponseStream, 0, False);
    end;
    
  finally
    // Cleanup
    FreeAndNil(LURI);
    FreeAndNil(ResponseStream);

    // Gemini requires connection close after each request
    if AContext.Connection.Connected then
    begin
      AContext.Connection.Disconnect;
    end;
  end;
end;

end.
