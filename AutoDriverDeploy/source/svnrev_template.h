#ifndef SVNREV_H
#define SVNREV_H

#define SVN_REV $WCREV$

#define SVN_REV_D "$WCDATE=%d$"
#define SVN_REV_M "$WCDATE=%m$"
#define SVN_REV_Y $WCDATE=%Y$

#if $WCMODS?1:0$
#define SVN_REV_STR "R$WCREV$[Modified] ($WCNOW=%d.%m.%Y$)"
#define SVN_REV2    "R$WCREV$[Modified]"
#else
#define SVN_REV_STR "R$WCREV$ ($WCDATE=%d.%m.%Y$)"
#define SVN_REV2    "R$WCREV$"
#endif

#endif
