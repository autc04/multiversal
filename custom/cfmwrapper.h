#pragma once

#include <Multiverse.h>

typedef struct
{
    ConnectionID conn;
    UniversalProcPtr proc;
} __cfmsym;

OSErr __cfmwrapper_connect(__cfmsym *si, const unsigned char *library, const unsigned char *name, uint32_t procInfo);
void __cfmwrapper_disconnect(__cfmsym *si);