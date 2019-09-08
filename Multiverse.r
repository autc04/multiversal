#ifndef _MULTIVERSE_R_
#define _MULTIVERSE_R_

type 'SIZE'
{
    boolean reserved;
    boolean ignoreSuspendResumeEvents, acceptSuspendResumeEvents;
    boolean reserved;
    boolean cannotBackground, canBackground;
    boolean needsActivateOnFGSwitch, doesActivateOnFGSwitch, multiFinderAware = true;
    boolean backgroundAndForeground, onlyBackground;
    boolean dontGetFrontClicks, getFrontClicks;
    boolean ignoreChildDiedEvents, acceptChildDiedEvents;
    boolean not32BitCompatible, is32BitCompatible;
    boolean notHighLevelEventAware, isHighLevelEventAware, reserved = false;
    boolean onlyLocalHLEvents, localAndRemoteHLEvents, reserved = false;
    boolean notStationeryAware, isStationeryAware, reserved = false;
    boolean dontUseTextEditServices, useTextEditServices, reserved = false;
    boolean notDisplayManagerAware, displayManagerAware, reserved = false;
    boolean reserved;
    boolean reserved;

    unsigned longint;   // preferred 
    unsigned longint;   // minimum
};

type 'cfrg'
{
    longint = 0;
    longint = 0;
    longint = 1;    // version
    longint = 0;
    longint = 0;
    longint = 0;
    longint = 0;
    longint = $$CountOf(fragments);
    array fragments
    {
        literal longint kPowerPC = 'pwpc', kPowerPCCFragArch = 'pwpc';
        int kFullLib = 0, kIsCompleteCFrag = 0, kUpdateLib = 1;
        hex longint kNoVersionNum = 0;
        hex longint kNoVersionNum = 0;
        longint kDefaultStackSize = 0;
        integer kNoAppSubFolder = 0;
        byte kIsLib = 0, kIsApp = 1, kLibraryCFrag = 0, kApplicationCFrag = 1;
        byte kOnDiskFlat = 1, kDataForkCFragLocator = 1, kOnDiskSegmented = 2;
        longint kZeroOffset = 0;
        longint kWholeFork = 0, kCFragGoesToEOF = 0;
        longint = 0;
        longint = 0;
        pstring;
        align long;
    };
};

type 'rdes'
{
    hex string = $"AAFE 0700 0000 0000 0000 0000";
    binary longint; // proc info
    hex string = $"0001 0007 0000 0020 0000 0000 0000 0000";
};

type 'STR '
{
    pstring;
};

type 'STR#'
{
    integer = $$CountOf(strings);
    array strings { pstring; };
};

type 'ICN#'
{
    array { hex string[128]; };
};

type 'ics#'
{
    array { hex string[32]; };
};

type 'icl8'
{
    hex string[1024];
};

type 'ics8'
{
    hex string[256];
};

type 'icl4'
{
    hex string[512];
};

type 'ics4'
{
    hex string[128];
};

type 'FREF'
{
    literal longint;
    integer;
    pstring;
};

type 'BNDL'
{
    literal longint;
    integer;
    integer = $$CountOf(types) - 1;
    array types
    {
        literal longint;
        integer = $$CountOf(frefs) - 1;
        array frefs
        {
            integer;
            integer;
        };
    };
};

type 'vers'
{
    hex byte;
    hex byte;
    hex byte development = 0x20, alpha = 0x40, beta = 0x60, release = 0x80;
    hex byte;
    integer verUS = 0, verAustria = 92;
    pstring;
    pstring;
};

type 'WIND'
{
    rect;
    integer documentProc, dBoxProc, plainDBox, altDBoxProc, noGrowDocProc,
        movableDBoxProc, zoomDocProc = 8, zoomNoGrow = 12, rDocProc = 16;
    byte invisible, visible;
    fill byte;
    byte noGoAway, goAway;
    fill byte;
    hex unsigned longint;
    pstring;
    align word;
    unsigned integer noAutoCenter = 0x0000, centerMainScreen = 0x280a,
        alertPositionMainScreen = 0x300a, staggerMainScreen = 0x380a,
        centerParentWindow = 0xa80a, alertPositionParentWindow = 0xb00a,
        staggerParentWindow = 0xb80a, centerParentWindowScreen = 0x680a,
        alertPositionParentWindowScreen = 0x700a, staggerParentWindowScreen = 0x780a;
};

type 'DLOG'
{
    rect;
    integer documentProc, dBoxProc, plainDBox, altDBoxProc, noGrowDocProc,
        movableDBoxProc, zoomDocProc = 8, zoomNoGrow = 12, rDocProc = 16;
    byte invisible, visible;
    fill byte;
    byte noGoAway, goAway;
    fill byte;
    hex unsigned longint;   // refCon
    integer;
    pstring;
    align word;
    unsigned integer noAutoCenter = 0x0000, centerMainScreen = 0x280a,
        alertPositionMainScreen = 0x300a, staggerMainScreen = 0x380a,
        centerParentWindow = 0xa80a, alertPositionParentWindow = 0xb00a,
        staggerParentWindow = 0xb80a, centerParentWindowScreen = 0x680a,
        alertPositionParentWindowScreen = 0x700a, staggerParentWindowScreen = 0x780a;
};

type 'ALRT'
{
    rect;
    integer;
    array [4]
    {
        boolean OK, Cancel;
        boolean invisible, visible;
        unsigned bitstring[2] silent, sound1, sound2, sound3;
    };
    unsigned integer noAutoCenter = 0x0000, centerMainScreen = 0x280a,
        alertPositionMainScreen = 0x300a, staggerMainScreen = 0x380a,
        centerParentWindow = 0xa80a, alertPositionParentWindow = 0xb00a,
        staggerParentWindow = 0xb80a, centerParentWindowScreen = 0x680a,
        alertPositionParentWindowScreen = 0x700a, staggerParentWindowScreen = 0x780a;
};

type 'DITL'
{
    integer = $$CountOf(items) - 1;
    array items
    {
        fill long;
        rect;
        switch {
            case UserItem:
                boolean enabled, disabled;
                key bitstring[7] = 0;
                fill byte;
            case Button:
                boolean enabled, disabled;
                key bitstring[7] = 4;
                pstring;
            case CheckBox:
                boolean enabled, disabled;
                key bitstring[7] = 5;
                pstring;
            case RadioButton:
                boolean enabled, disabled;
                key bitstring[7] = 6;
                pstring;
            case Control:
                boolean enabled, disabled;
                key bitstring[7] = 7;
                byte = 2;
                integer;
            case StaticText:
                boolean enabled, disabled;
                key bitstring[7] = 8;
                pstring;
            case EditText:
                boolean enabled, disabled;
                key bitstring[7] = 16;
                pstring;
            case Icon:
                boolean enabled, disabled;
                key bitstring[7] = 32;
                byte = 2;
                integer;
            case Picture:
                boolean enabled, disabled;
                key bitstring[7] = 64;
                byte = 2;
                integer;
            case HelpItem:
                longint = 0;
                longint = 0;
                longint = 0;
                boolean enabled, disabled;
                key bitstring[7] = 1;
                switch
                {
                    case HMScanhdlg:
                        longint = 4;
                        key integer = 1;
                        integer;
                    case HMScanhrct:
                        longint = 4;
                        key integer = 2;
                        integer;
                    case HMScanAppendhdlg:
                        longint = 6;
                        key integer = 8;
                        integer;
                        integer;
                };
        };
        align word;
    };
};

type 'MENU'
{
    integer;
    integer = 0;
    integer = 0;
    integer textMenuProc = 0;
    fill word;
    hex bitstring[31] allEnabled=0x7FFFFFFF;
    boolean disabled, enabled;
    pstring apple = "\0x14";
    array
    {
        pstring;
        byte noIcon;
        char noKey = "\0x00", hierarchicalMenu = "\0x$1B";
        char noMark = "\0x00", check = "\0x12";
        byte plain;
    };
    fill byte;
};

type 'MBAR'
{
    integer = $$CountOf(menus);
    array menus { integer; };
};

#endif