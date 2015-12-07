unit dddToolsAdminMain;

{$I Synopse.inc} // define HASINLINE USETYPEINFO CPU32 CPU64 OWNNORMTOUPPER

interface

uses
  Windows,
  Messages,
  SysUtils,
  Variants,
  Classes,
  Graphics,
  Controls,
  Forms,
  Dialogs,
  Clipbrd,
  mORMotUI,
  mORMotUILogin,
  mORMotToolbar,
  SynTaskDialog,
  SynCommons,
  mORMot,
  mORMotHttpClient,
  mORMotDDD,
  dddInfraApps,
  dddToolsAdminDB,
  dddToolsAdminLog;

type
  TAdminSaveOrExport = (expSaveGrid, expCopyGrid, expCopyRow);

  TAdminControl = class(TWinControl)
  protected
    fClient: TSQLHttpClientWebsockets;
    fAdmin: IAdministratedDaemon;
    fDatabases: TRawUTF8DynArray;
    fPage: TSynPager;
    fPages: array of TSynPage;
    fLogFrame: TLogFrame;
    fLogFrames: TLogFrameDynArray;
    fChatPage: TSynPage;
    fChatFrame: TLogFrame;
    fDBFrame: TDBFrameDynArray;
    fDefinition: TDDDRestClientSettings;
    fDlgSave: TSaveDialog;
  public
    LogFrameClass: TLogFrameClass;
    DBFrameClass: TDBFrameClass;
    Version: Variant;
    OnAfterExecute: TNotifyEvent;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Open(Definition: TDDDRestClientSettings; Model: TSQLModel = nil):
      boolean; virtual;
    procedure Show; virtual;
    function GetState: Variant; virtual;
    function AddPage(const aCaption: RawUTF8): TSynPage; virtual;
    function AddDBFrame(const aCaption, aDatabaseName: RawUTF8; aClass:
      TDBFrameClass): TDBFrame; virtual;
    function AddLogFrame(page: TSynPage; const aCaption, aEvents, aPattern:
      RawUTF8; aClass: TLogFrameClass): TLogFrame; virtual;
    procedure EndLog(aLogFrame: TLogFrame); virtual;
    procedure OnPageChange(Sender: TObject); virtual;
    function CurrentDBFrame: TDBFrame;
    function FindDBFrame(const aDatabaseName: RawUTF8): TDBFrame;
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState); virtual;
    procedure SaveOrExport(Fmt: TAdminSaveOrExport; const ContextName: string =
      ''; DB: TDBFrame = nil);
    property Client: TSQLHttpClientWebsockets read fClient;
    property Page: TSynPager read fPage;
    property LogFrame: TLogFrame read fLogFrame;
    property DBFrame: TDBFrameDynArray read fDBFrame;
    property ChatPage: TSynPage read fChatPage;
    property ChatFrame: TLogFrame read fChatFrame;
  end;

  TAdminForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
  protected
    fFrame: TAdminControl;
  public
    property Frame: TAdminControl read fFrame;
  end;

var
  AdminForm: TAdminForm;

function AskForUserIfVoid(Definition: TDDDRestClientSettings): boolean;

implementation

{$R *.dfm}

function AskForUserIfVoid(Definition: TDDDRestClientSettings): boolean;
var
  U, P: string;
begin
  result := false;
  if Definition.ORM.User = '' then
    if TLoginForm.Login(Application.Mainform.Caption, Format('Credentials for %s',
      [Definition.ORM.ServerName]), U, P, true, '') then begin
      Definition.ORM.User := StringToUTF8(U);
      Definition.ORM.PasswordPlain := StringToUTF8(P);
    end
    else
      exit;
  result := true;
end;

var
  AdminControlConnecting: TForm; // only one Open() attempt at once

function TAdminControl.Open(Definition: TDDDRestClientSettings; Model: TSQLModel):
  boolean;
var
  exec: TServiceCustomAnswer;
begin
  result := false;
  if Assigned(fAdmin) or (Definition.Orm.User = '') or Assigned(AdminControlConnecting)
    then
    exit;
  try
    AdminControlConnecting := CreateTempForm('Connecting to ' + Definition.ORM.ServerName);
    try
      Application.ProcessMessages;
      if Model = nil then
        Model := TSQLModel.Create([], '');
      Model.OnClientIdle := TLoginForm.OnIdleProcess; // allow basic UI interactivity
      fClient := AdministratedDaemonClient(Definition, Model);
      if not fClient.Services.Resolve(IAdministratedDaemon, fAdmin) then
        raise EDDDRestClient.CreateUTF8('Resolve(IAdministratedDaemon)=false: check % version',
          [Definition.ORM.ServerName]);
      exec := fAdmin.DatabaseExecute('', '#version');
      version := _JsonFast(exec.Content);
      fDefinition := Definition;
      result := true;
    finally
      FreeAndNil(AdminControlConnecting);
      fClient.OnIdle := nil; // back to default blocking behavior (safer UI)
    end;
  except
    on E: Exception do begin
      ShowException(E);
      FreeAndNil(fClient);
    end;
  end;
end;

function TAdminControl.GetState: Variant;
var
  exec: TServiceCustomAnswer;
begin
  if fAdmin <> nil then begin
    exec := fAdmin.DatabaseExecute('', '#state');
    result := _JsonFast(exec.Content);
  end;
end;

procedure TAdminControl.Show;
var
  i, n: integer;
  f: TDBFrame;
begin
  if (fClient = nil) or (fAdmin = nil) or (fPage <> nil) then
    exit; // show again after hide
  if LogFrameClass = nil then
    LogFrameClass := TLogFrame;
  if DBFrameClass = nil then
    DBFrameClass := TDBFrame;
  fDatabases := fAdmin.DatabaseList;
  fPage := TSynPager.Create(self);
  fPage.ControlStyle := fPage.ControlStyle + [csClickEvents]; // enable OnDblClick
  fPage.Parent := self;
  fPage.Align := alClient;
  fPage.OnChange := OnPageChange;
  n := length(fDatabases);
  fLogFrame := AddLogFrame(nil, 'log', '', '', LogFrameClass);
  if n > 0 then begin
    for i := 0 to n - 1 do begin
      f := AddDBFrame(fDatabases[i], fDatabases[i], DBFrameClass);
      f.Open;
      if i = 0 then
        fPage.ActivePageIndex := 1;
    end;
    Application.ProcessMessages;
    fDBFrame[0].mmoSQL.SetFocus;
  end;
  fChatPage := AddPage('Chat');
  fChatPage.TabVisible := false;
end;

procedure TAdminControl.EndLog(aLogFrame: TLogFrame);
begin
  if aLogFrame <> nil then
  try
    Screen.Cursor := crHourGlass;
    if aLogFrame.Callback <> nil then begin
      fClient.Services.CallBackUnRegister(aLogFrame.Callback);
      aLogFrame.Callback := nil;
    end;
    aLogFrame.Closing;
  finally
    Screen.Cursor := crDefault;
  end;
end;

constructor TAdminControl.Create(AOwner: TComponent);
begin
  inherited;
  fDlgSave := TSaveDialog.Create(AOwner);
  fDlgSave.Options := [ofOverwritePrompt, ofHideReadOnly, ofPathMustExist,
    ofEnableSizing];
  fDlgSave.Filter :=
    'JSON (human readable)|*.json|JSON (small)|*.json|CSV (text)|*.txt|Excel/Office (.ods)|*.ods|HTML|*.html';
  fDlgSave.DefaultExt := '.html';
  fDlgSave.FilterIndex := 5;
  fDlgSave.InitialDir := GetShellFolderPath(CSIDL_DOCUMENTS);
end;

destructor TAdminControl.Destroy;
var
  i: integer;
begin
  if fClient <> nil then
    fClient.OnIdle := TLoginForm.OnIdleProcess; // allow basic UI interactivity
  for i := 0 to high(fLogFrames) do begin
    EndLog(fLogFrames[i]);
    fLogFrames[i].Admin := nil;
    fLogFrames[i] := nil;
  end;
  Finalize(fLogFrames);
  for i := 0 to high(fDBFrame) do
    fDBFrame[i].Admin := nil;
  fDBFrame := nil;
  fAdmin := nil;
  fDefinition.Free;
  if fClient <> nil then begin
    for i := 1 to 10 do begin
      Sleep(50); // leave some time to flush all pending CallBackUnRegister()
      Application.ProcessMessages;
    end;
    FreeAndNil(fClient);
  end;
  inherited Destroy;
end;

procedure TAdminControl.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

  procedure LogKeys(aLogFrame: TLogFrame);
  begin
    if aLogFrame <> nil then
      case Key of
        VK_F3:
          aLogFrame.btnSearchNextClick(aLogFrame.btnSearchNext);
        ord('A')..ord('Z'), Ord('0')..ord('9'), 32:
          if (shift = []) and (aLogFrame.ClassType <> TLogFrameChat) and not
            aLogFrame.edtSearch.Focused then
            aLogFrame.edtSearch.Text := aLogFrame.edtSearch.Text + string(Char(Key))
          else if (key = ord('F')) and (ssCtrl in Shift) then begin
            aLogFrame.edtSearch.SelectAll;
            aLogFrame.edtSearch.SetFocus;
          end;
      end;
  end;

var
  page: TControl;
  ndx: integer;
begin
  page := fPage.ActivePage;
  if page = nil then
    exit;
  ndx := page.Tag;
  if ndx > 0 then begin
    ndx := ndx - 1; // see AddDBFrame()
    if cardinal(ndx) < cardinal(length(fDBFrame)) then
      with fDBFrame[ndx] do
        case Key of
          VK_F5:
            btnCmdClick(btnCmd);
          VK_F9:
            btnExecClick(btnExec);
          ord('A'):
            if ssCtrl in Shift then begin
              mmoSQL.SelectAll;
              mmoSQL.SetFocus;
            end;
          ord('H'):
            if ssCtrl in Shift then
              btnHistoryClick(btnHistory);
        end
  end
  else if ndx < 0 then begin
    ndx := -(ndx + 1); // see AddLogFrame()
    if cardinal(ndx) < cardinal(length(fLogFrames)) then
      LogKeys(fLogFrames[ndx]);
  end;
end;

function TAdminControl.AddPage(const aCaption: RawUTF8): TSynPage;
var
  n: integer;
begin
  n := length(fPages);
  SetLength(fPages, n + 1);
  result := TSynPage.Create(self);
  result.Caption := UTF8ToString(aCaption);
  result.PageControl := fPage;
  fPages[n] := result;
end;

function TAdminControl.AddDBFrame(const aCaption, aDatabaseName: RawUTF8; aClass:
  TDBFrameClass): TDBFrame;
var
  page: TSynPage;
  n: integer;
begin
  page := AddPage(aCaption);
  n := length(fDBFrame);
  SetLength(fDBFrame, n + 1);
  result := aClass.Create(self);
  result.Name := format('DBFrame%s', [aCaption]);
  result.Parent := page;
  result.Align := alClient;
  result.Client := fClient;
  result.Admin := fAdmin;
  result.DatabaseName := aDatabaseName;
  result.OnAfterExecute := OnAfterExecute;
  fDBFrame[n] := result;
  page.Tag := n + 1; // Tag>0 -> index in fDBFrame[Tag-1] -> used in FormKeyDown
end;

function TAdminControl.AddLogFrame(page: TSynPage; const aCaption, aEvents,
  aPattern: RawUTF8; aClass: TLogFrameClass): TLogFrame;
var
  n: integer;
begin
  if page = nil then begin
    page := AddPage(aCaption);
    fPage.ActivePageIndex := fPage.PageCount - 1;
  end;
  if aEvents = '' then
    result := aClass.Create(self, fAdmin)
  else
    result := aClass.CreateCustom(self, fAdmin, aEvents, aPattern);
  result.Parent := page;
  result.Align := alClient;
  n := length(fLogFrames);
  SetLength(fLogFrames, n + 1);
  fLogFrames[n] := result;
  page.Tag := -(n + 1); // Tag<0 -> index in fLogFrames[-(Tag+1)] -> used in FormKeyDown
end;

procedure TAdminControl.OnPageChange(Sender: TObject);
var
  ndx: cardinal;
begin
  if fPage.ActivePage = fChatPage then begin
    if fChatFrame = nil then
      fChatFrame := AddLogFrame(fChatPage, '', 'Monitoring', '[CHAT] ', TLogFrameChat);
    exit;
  end;
  ndx := fPage.ActivePageIndex - 1;
  if ndx >= cardinal(Length(fDBFrame)) then
    exit;
end;

function TAdminControl.CurrentDBFrame: TDBFrame;
var
  ndx: cardinal;
begin
  ndx := fPage.ActivePageIndex - 1;
  if ndx >= cardinal(Length(fDBFrame)) then
    result := nil
  else
    result := fDBFrame[ndx];
end;

function TAdminControl.FindDBFrame(const aDatabaseName: RawUTF8): TDBFrame;
var
  i: Integer;
begin
  for i := 0 to high(fDBFrame) do
    if IdemPropNameU(fDBFrame[i].DatabaseName, aDatabaseName) then begin
      result := fDBFrame[i];
      exit;
    end;
  result := nil;
end;

procedure TAdminControl.SaveOrExport(Fmt: TAdminSaveOrExport; const ContextName:
  string; DB: TDBFrame);
var
  grid: TSQLTable;
  row: integer;
  table: RawUTF8;
begin
  if DB = nil then
    DB := CurrentDBFrame;
  if DB = nil then
    exit;
  grid := DB.Grid.Table;
  if (grid = nil) or (grid.RowCount = 0) then
    exit;
  if Fmt = expSaveGrid then begin
    fDlgSave.FileName := SysUtils.Trim(Format('%s %s %s', [ContextName, db.GridLastTableName,
      NowToString(false)]));
    if not fDlgSave.Execute then
      exit;
    case fDlgSave.FilterIndex of
      1:
        JSONBufferReformat(pointer(grid.GetJSONValues(true)), table);
      2:
        table := grid.GetJSONValues(true);
      3:
        table := grid.GetCSVValues(true);
      4:
        table := grid.GetODSDocument;
      5:
        table := grid.GetHtmlTable;
    end;
    if table <> '' then
      FileFromString(table, fDlgSave.FileName);
  end
  else begin
    case Fmt of
      expCopyGrid:
        table := grid.GetCSVValues(true);
      expCopyRow:
        begin
          row := db.drwgrdResult.Row;
          if row < 0 then
            exit;
          table := grid.GetCSVValues(true, ',', false, row, row);
        end;
    end;
    if table <> '' then
      Clipboard.AsText := UTF8ToString(table);
  end;
end;


{ TAdminForm }

procedure TAdminForm.FormCreate(Sender: TObject);
begin
  DefaultFont.Name := 'Tahoma';
  DefaultFont.Size := 9;
  Caption := Format('%s %s', [ExeVersion.ProgramName, ExeVersion.Version.Detailed]);
  fFrame := TAdminControl.Create(self);
  fFrame.Parent := self;
  fFrame.Align := alClient;
  OnKeyDown := fFrame.FormKeyDown;
end;

procedure TAdminForm.FormShow(Sender: TObject);
begin
  fFrame.Show;
  Caption := Format('%s - %s %s via %s', [ExeVersion.ProgramName, fFrame.version.prog,
    fFrame.version.version, fFrame.fDefinition.ORM.ServerName]);
end;

end.

