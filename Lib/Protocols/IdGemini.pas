unit IdGemini;

interface

uses
  SysUtils, Classes, IdTCPClient, IdGlobal, IdException, IdSSL,
  IdSSLOpenSSL, IdSSLOpenSSLHeaders, IdURI, IdIDN;

type
  TGeminiStatus = (gsUnknown, gsInput, gsSensitiveInput, gsSuccess, 
    gsRedirectTemporary, gsRedirectPermanent, gsTempFailure, gsPermFailure, 
    gsCertRequired, gsCertNotAuthorized, gsCertNotValid);

  TGeminiResponse = class
  public
    Status: TGeminiStatus;
    StatusCode: Integer;
    Meta: string;
    Content: TMemoryStream;
    ContentType: string;
    Charset: string;
    constructor Create;
    destructor Destroy; override;
  end;

  TIdGeminiOnRedirectEvent = procedure(Sender: TObject; var NewLocation: String;
    var RedirectCount: Integer; var Handled: Boolean) of object;

  TIdGemini = class(TIdTCPClient)
  private
    FSSLIOHandler: TIdSSLIOHandlerSocketOpenSSL;
    FRedirectCount: Integer;
    FRedirectMax: Integer;
    FHandleRedirects: Boolean;
    FOnRedirect: TIdGeminiOnRedirectEvent;
    function StatusCodeToEnum(Code: Integer): TGeminiStatus;
  protected
    function InternalRequest(const AURL: string): TGeminiResponse;
    procedure InitComponent; override;
  public
    destructor Destroy; override;
    function Request(const AURL: string): TGeminiResponse;
    property SSLIOHandler: TIdSSLIOHandlerSocketOpenSSL read FSSLIOHandler;
  published
    property HandleRedirects: Boolean read FHandleRedirects write FHandleRedirects default True;
    property RedirectMax: Integer read FRedirectMax write FRedirectMax default 5;
    property OnRedirect: TIdGeminiOnRedirectEvent read FOnRedirect write FOnRedirect;
    property Port default 1965;
  end;

implementation

{ TGeminiResponse }

constructor TGeminiResponse.Create;
begin
  inherited Create;
  Status := gsUnknown;
  StatusCode := 0;
  Meta := '';
  Content := nil;
  ContentType := '';
  Charset := '';
end;

destructor TGeminiResponse.Destroy;
begin
  FreeAndNil(Content);
  inherited Destroy;
end;

{ TIdGemini }

procedure TIdGemini.InitComponent;
begin
  inherited InitComponent;
  FHandleRedirects := True;
  FRedirectMax := 5;
  Port := 1965;
  
  // Create and configure SSL/TLS handler
  FSSLIOHandler := TIdSSLIOHandlerSocketOpenSSL.Create(Self);
  FSSLIOHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLIOHandler.SSLOptions.Mode := sslmClient;
  FSSLIOHandler.SSLOptions.VerifyMode := [];
  FSSLIOHandler.SSLOptions.VerifyDepth := 0;
  IOHandler := FSSLIOHandler;
  
  InitIDNLibrary;
end;

destructor TIdGemini.Destroy;
begin
  inherited Destroy;
end;

function TIdGemini.StatusCodeToEnum(Code: Integer): TGeminiStatus;
begin
  case Code of
    10: Result := gsInput;
    11: Result := gsSensitiveInput;
    20..29: Result := gsSuccess;
    30: Result := gsRedirectTemporary;
    31: Result := gsRedirectPermanent;
    40..49: Result := gsTempFailure;
    50..59: Result := gsPermFailure;
    60: Result := gsCertRequired;
    61: Result := gsCertNotAuthorized;
    62: Result := gsCertNotValid;
  else
    Result := gsUnknown;
  end;
end;

function TIdGemini.InternalRequest(const AURL: string): TGeminiResponse;
var
  StatusLine: string;
  StatusCode: Integer;
  LURI: TIdURI;
  ParamPos: Integer;
begin
  Result := TGeminiResponse.Create;
  LURI := nil;

  try
    // Parse URL to set host and port
    LURI := TIdURI.Create(AURL);
    
    // Set connection parameters
    Host := LURI.Host;
    if LURI.Port <> '' then
      Port := IndyStrToInt(LURI.Port, 1965)
    else
      Port := 1965;

    // Connect if not already connected
    if not Connected then
      Connect;

    // Send request (URL + CRLF)
    IOHandler.WriteLn(AURL);

    // Read status line
    StatusLine := IOHandler.ReadLn;
    
    if Length(StatusLine) < 3 then
    begin
      Result.Status := gsUnknown;
      Result.Meta := 'Invalid response';
      Exit;
    end;

    // Parse status code (first two characters)
    StatusCode := StrToIntDef(Copy(StatusLine, 1, 2), -1);
    Result.StatusCode := StatusCode;
    Result.Status := StatusCodeToEnum(StatusCode);

    // Parse meta (everything after "XX " where XX is status code)
    if Length(StatusLine) > 3 then
      Result.Meta := Trim(Copy(StatusLine, 4, MaxInt))
    else
      Result.Meta := '';

    // Read content for success responses
    if Result.Status = gsSuccess then
    begin
      // Parse MIME type and charset from meta
      ParamPos := Pos(';', Result.Meta);
      if ParamPos > 0 then
      begin
        Result.ContentType := Trim(Copy(Result.Meta, 1, ParamPos - 1));
        Result.Charset := Trim(Copy(Result.Meta, ParamPos + 1, MaxInt));
        // Remove charset= prefix if present
        if Pos('charset=', LowerCase(Result.Charset)) = 1 then
          Result.Charset := Trim(Copy(Result.Charset, 9, MaxInt));
      end
      else
      begin
        Result.ContentType := Trim(Result.Meta);
        Result.Charset := '';
      end;

      // Read content until connection closes
      Result.Content := TMemoryStream.Create;
      try
        IOHandler.ReadStream(Result.Content, -1, True);
        Result.Content.Position := 0;
      except
        on E: EIdSilentException do
        begin
          // Connection closed gracefully - expected for Gemini
        end;
      end;
    end;

  except
    on E: Exception do
    begin
      FreeAndNil(Result);
      raise;
    end;
  end;
  
  FreeAndNil(LURI);
end;

function TIdGemini.Request(const AURL: string): TGeminiResponse;
var
  LCurrentURL: string;
  LNewLocation: string;
  LHandled: Boolean;
  LURI: TIdURI;
begin
  FRedirectCount := 0;
  LCurrentURL := AURL;
  Result := nil;

  try
    repeat
      // Free previous response if redirecting
      if Result <> nil then
        FreeAndNil(Result);

      // Disconnect before making new request (Gemini closes after each response)
      if Connected then
        Disconnect;

      // Make request
      Result := InternalRequest(LCurrentURL);

      // Handle redirect if needed
      if ((Result.Status = gsRedirectTemporary) or (Result.Status = gsRedirectPermanent)) 
         and FHandleRedirects and (FRedirectCount < FRedirectMax) then
      begin
        Inc(FRedirectCount);
        LNewLocation := Result.Meta;
        LHandled := False;

        // Fire redirect event
        if Assigned(FOnRedirect) then
          FOnRedirect(Self, LNewLocation, FRedirectCount, LHandled);

        if not LHandled then
        begin
          // Parse the new location
          LURI := TIdURI.Create(LNewLocation);
          try
            // Handle relative URLs
            if LURI.Protocol = '' then
            begin
              // Relative URL - combine with current URL
              LURI.Free;
              LURI := TIdURI.Create(LCurrentURL);
              
              // Simple relative path handling
              if (LNewLocation <> '') and (LNewLocation[1] = '/') then
              begin
                LCurrentURL := LURI.Protocol + '://' + LURI.Host;
                if LURI.Port <> '' then
                  LCurrentURL := LCurrentURL + ':' + LURI.Port;
                LCurrentURL := LCurrentURL + LNewLocation;
              end
              else
                LCurrentURL := LNewLocation;
            end
            else if SameText(LURI.Protocol, 'gemini') then
            begin
              // Absolute Gemini URL
              LCurrentURL := LNewLocation;
            end
            else
            begin
              // Different protocol - stop redirecting
              Break;
            end;
          finally
            LURI.Free;
          end;
        end
        else
        begin
          // Event handler marked redirect as handled
          Break;
        end;
      end
      else
      begin
        // Not a redirect or redirect handling disabled
        Break;
      end;
    until False;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

end.
