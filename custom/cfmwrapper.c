#include "cfmwrapper.h"


OSErr __cfmwrapper_connect(__cfmsym *si, const unsigned char *library, const unsigned char *name, uint32_t procInfo)
{
    OSErr err = noErr;
    uint32_t arch;
    Str255 errName;
    Ptr mainAddr, symPtr;

    err = Gestalt(gestaltSysArchitecture, &arch);
    if(err)
        return err;

    err = GetSharedLibrary(library, arch == gestalt68k ? kMotorola68KArch : kPowerPCArch, kReferenceCFrag, &si->conn, &mainAddr, errName);
    if(err)
        return err;

    err = FindSymbol(si->conn, name, &symPtr, NULL);
    if(err)
    {
        CloseConnection(&si->conn);
        si->conn = NULL;
        return err;
    }

    si->proc = NewRoutineDescriptor((ProcPtr)symPtr, procInfo, arch == gestalt68k ? kM68kISA : kPowerPCISA);
    return noErr;
}

void __cfmwrapper_disconnect(__cfmsym *si)
{
    DisposeRoutineDescriptor(si->proc);
    CloseConnection(&si->conn);
}
