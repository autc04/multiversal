#include <Multiverse.h>

pascal Boolean NavServicesAvailable()
{
    if(*(short*) 0x028E /* ROM85 */ <= 0)
        return false;
    if(GetToolTrapAddress(_CodeFragmentDispatch) == GetToolTrapAddress(_Unimplemented))
        return false;

    return NavServicesCanRun();
}
