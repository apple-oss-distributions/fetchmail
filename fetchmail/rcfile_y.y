%{
/*
 * rcfile_y.y -- Run control file parser for fetchmail
 *
 * For license terms, see the file COPYING in this directory.
 */

#include "config.h"
#include <stdio.h>
#include <sys/types.h>
#include <sys/file.h>
#if defined(HAVE_SYS_WAIT_H)
#include <sys/wait.h>
#endif
#include <sys/stat.h>
#include <errno.h>
#if defined(STDC_HEADERS)
#include <stdlib.h>
#endif
#if defined(HAVE_UNISTD_H)
#include <unistd.h>
#endif
#include <string.h>

#if NET_SECURITY
#include <net/security.h>
#endif /* NET_SECURITY */

#include "fetchmail.h"
#include "i18n.h"
  
/* parser reads these */
char *rcfile;			/* path name of rc file */
struct query cmd_opts;		/* where to put command-line info */

/* parser sets these */
struct query *querylist;	/* head of server list (globally visible) */

int yydebug;			/* in case we didn't generate with -- debug */

static struct query current;	/* current server record */
static int prc_errflag;
static struct hostdata *leadentry;
static flag trailer;

static void record_current(void);
static void user_reset(void);
static void reset_server(const char *name, int skip);

/* these should be of size PATH_MAX */
char currentwd[1024] = "", rcfiledir[1024] = "";

/* using Bison, this arranges that yydebug messages will show actual tokens */
extern char * yytext;
#define YYPRINT(fp, type, val)	fprintf(fp, " = \"%s\"", yytext)
%}

%union {
  int proto;
  int number;
  char *sval;
}

%token DEFAULTS POLL SKIP VIA AKA LOCALDOMAINS PROTOCOL
%token AUTHENTICATE TIMEOUT KPOP SDPS ENVELOPE QVIRTUAL
%token USERNAME PASSWORD FOLDER SMTPHOST FETCHDOMAINS MDA BSMTP LMTP
%token SMTPADDRESS SMTPNAME SPAMRESPONSE PRECONNECT POSTCONNECT LIMIT WARNINGS
%token NETSEC INTERFACE MONITOR PLUGIN PLUGOUT
%token IS HERE THERE TO MAP WILDCARD
%token BATCHLIMIT FETCHLIMIT EXPUNGE PROPERTIES
%token SET LOGFILE DAEMON SYSLOG IDFILE INVISIBLE POSTMASTER BOUNCEMAIL 
%token SPAMBOUNCE SHOWDOTS
%token <proto> PROTO AUTHTYPE
%token <sval>  STRING
%token <number> NUMBER
%token NO KEEP FLUSH FETCHALL REWRITE FORCECR STRIPCR PASS8BITS 
%token DROPSTATUS DROPDELIVERED
%token DNS SERVICE PORT UIDL INTERVAL MIMEDECODE IDLE CHECKALIAS 
%token SSL SSLKEY SSLCERT SSLPROTO SSLCERTCK SSLCERTPATH SSLFINGERPRINT
%token PRINCIPAL ESMTPNAME ESMTPPASSWORD
%token TRACEPOLLS

%%

rcfile		: /* empty */
		| statement_list
		;

statement_list	: statement
		| statement_list statement
		;

optmap		: MAP | /* EMPTY */;

/* future global options should also have the form SET <name> optmap <value> */
statement	: SET LOGFILE optmap STRING	{run.logfile = prependdir ($4, rcfiledir);}
		| SET IDFILE optmap STRING	{run.idfile = prependdir ($4, rcfiledir);}
		| SET DAEMON optmap NUMBER	{run.poll_interval = $4;}
		| SET POSTMASTER optmap STRING	{run.postmaster = xstrdup($4);}
		| SET BOUNCEMAIL		{run.bouncemail = TRUE;}
		| SET NO BOUNCEMAIL		{run.bouncemail = FALSE;}
		| SET SPAMBOUNCE		{run.spambounce = TRUE;}
		| SET NO SPAMBOUNCE		{run.spambounce = FALSE;}
		| SET PROPERTIES optmap STRING	{run.properties =xstrdup($4);}
		| SET SYSLOG			{run.use_syslog = TRUE;}
		| SET NO SYSLOG			{run.use_syslog = FALSE;}
		| SET INVISIBLE			{run.invisible = TRUE;}
		| SET NO INVISIBLE		{run.invisible = FALSE;}
		| SET SHOWDOTS			{run.showdots = TRUE;}
		| SET NO SHOWDOTS		{run.showdots = FALSE;}

/* 
 * The way the next two productions are written depends on the fact that
 * userspecs cannot be empty.  It's a kluge to deal with files that set
 * up a load of defaults and then have poll statements following with no
 * user options at all. 
 */
		| define_server serverspecs		{record_current();}
		| define_server serverspecs userspecs

/* detect and complain about the most common user error */
		| define_server serverspecs userspecs serv_option
			{yyerror(GT_("server option after user options"));}
		;

define_server	: POLL STRING		{reset_server($2, FALSE);}
		| SKIP STRING		{reset_server($2, TRUE);}
		| DEFAULTS		{reset_server("defaults", FALSE);}
  		;

serverspecs	: /* EMPTY */
		| serverspecs serv_option
		;

alias_list	: STRING		{save_str(&current.server.akalist,$1,0);}
		| alias_list STRING	{save_str(&current.server.akalist,$2,0);}
		;

domain_list	: STRING		{save_str(&current.server.localdomains,$1,0);}
		| domain_list STRING	{save_str(&current.server.localdomains,$2,0);}
		;

serv_option	: AKA alias_list
		| VIA STRING		{current.server.via = xstrdup($2);}
		| LOCALDOMAINS domain_list
		| PROTOCOL PROTO	{current.server.protocol = $2;}
		| PROTOCOL KPOP		{
					    current.server.protocol = P_POP3;

					    if (current.server.authenticate == A_PASSWORD)
#ifdef KERBEROS_V5
						current.server.authenticate = A_KERBEROS_V5;
#else
		    				current.server.authenticate = A_KERBEROS_V4;
#endif /* KERBEROS_V5 */
#if INET6_ENABLE
					    current.server.service = KPOP_PORT;
#else /* INET6_ENABLE */
					    current.server.port = KPOP_PORT;
#endif /* INET6_ENABLE */
					}
		| PRINCIPAL STRING	{current.server.principal = xstrdup($2);}
		| ESMTPNAME STRING	{current.server.esmtp_name = xstrdup($2);}
		| ESMTPPASSWORD STRING	{current.server.esmtp_password = xstrdup($2);}
		| PROTOCOL SDPS		{
#ifdef SDPS_ENABLE
					    current.server.protocol = P_POP3;
					    current.server.sdps = TRUE;
#else
					    yyerror(GT_("SDPS not enabled."));
#endif /* SDPS_ENABLE */
					}
		| UIDL			{current.server.uidl = FLAG_TRUE;}
		| NO UIDL		{current.server.uidl  = FLAG_FALSE;}
		| CHECKALIAS            {current.server.checkalias = FLAG_TRUE;}
		| NO CHECKALIAS         {current.server.checkalias  = FLAG_FALSE;}
		| SERVICE STRING	{
#if INET6_ENABLE
					current.server.service = $2;
#endif /* INET6_ENABLE */
					}
		| PORT NUMBER		{
#if INET6_ENABLE
					int port = $2;
					char buf[10];
					sprintf(buf, "%d", port);
					current.server.service = xstrdup(buf);
#else
					current.server.port = $2;
#endif /* INET6_ENABLE */
		}
		| INTERVAL NUMBER
			{current.server.interval = $2;}
		| AUTHENTICATE AUTHTYPE
			{current.server.authenticate = $2;}
		| TIMEOUT NUMBER
			{current.server.timeout = $2;}
		| ENVELOPE NUMBER STRING 
					{
					    current.server.envelope = 
						xstrdup($3);
					    current.server.envskip = $2;
					}
		| ENVELOPE STRING
					{
					    current.server.envelope = 
						xstrdup($2);
					    current.server.envskip = 0;
					}

		| QVIRTUAL STRING	{current.server.qvirtual=xstrdup($2);}
		| NETSEC STRING		{
#ifdef NET_SECURITY
					    void *request;
					    int requestlen;

		    			    if (net_security_strtorequest($2, &request, &requestlen))
						yyerror(GT_("invalid security request"));
					    else {
						current.server.netsec = xstrdup($2);
					        free(request);
					    }
#else
					    yyerror(GT_("network-security support disabled"));
#endif /* NET_SECURITY */
					}
		| INTERFACE STRING	{
#if (defined(linux) && !defined(INET6_ENABLE)) || defined(__FreeBSD__)
					interface_parse($2, &current.server);
#else /* (defined(linux) && !defined(INET6_ENABLE)) || defined(__FreeBSD__) */
					fprintf(stderr, GT_("fetchmail: interface option is only supported under Linux (without IPv6) and FreeBSD\n"));
#endif /* (defined(linux) && !defined(INET6_ENABLE)) || defined(__FreeBSD__) */
					}
		| MONITOR STRING	{
#if (defined(linux) && !defined(INET6_ENABLE)) || defined(__FreeBSD__)
					current.server.monitor = xstrdup($2);
#else /* (defined(linux) && !defined(INET6_ENABLE)) || defined(__FreeBSD__) */
					fprintf(stderr, GT_("fetchmail: monitor option is only supported under Linux (without IPv6) and FreeBSD\n"));
#endif /* (defined(linux) && !defined(INET6_ENABLE) || defined(__FreeBSD__)) */
					}
		| PLUGIN STRING		{ current.server.plugin = xstrdup($2); }
		| PLUGOUT STRING	{ current.server.plugout = xstrdup($2); }
		| DNS			{current.server.dns = FLAG_TRUE;}
		| NO DNS		{current.server.dns = FLAG_FALSE;}
		| NO ENVELOPE		{current.server.envelope = STRING_DISABLED;}
		| TRACEPOLLS		{current.tracepolls = FLAG_TRUE;}
		| NO TRACEPOLLS		{current.tracepolls = FLAG_FALSE;}
		;

userspecs	: user1opts		{record_current(); user_reset();}
		| explicits
		;

explicits	: explicitdef		{record_current(); user_reset();}
		| explicits explicitdef	{record_current(); user_reset();}
		;

explicitdef	: userdef user0opts
		;

userdef		: USERNAME STRING	{current.remotename = xstrdup($2);}
		| USERNAME mapping_list HERE
		| USERNAME STRING THERE	{current.remotename = xstrdup($2);}
		;

user0opts	: /* EMPTY */
		| user0opts user_option
		;

user1opts	: user_option
		| user1opts user_option
		;

localnames	: WILDCARD		{current.wildcard =  TRUE;}
		| mapping_list		{current.wildcard =  FALSE;}
		| mapping_list WILDCARD	{current.wildcard =  TRUE;}
		;

mapping_list	: mapping		
		| mapping_list mapping
		;

mapping		: STRING	
				{save_str_pair(&current.localnames, $1, NULL);}
		| STRING MAP STRING
				{save_str_pair(&current.localnames, $1, $3);}
		;

folder_list	: STRING		{save_str(&current.mailboxes,$1,0);}
		| folder_list STRING	{save_str(&current.mailboxes,$2,0);}
		;

smtp_list	: STRING		{save_str(&current.smtphunt, $1,TRUE);}
		| smtp_list STRING	{save_str(&current.smtphunt, $2,TRUE);}
		;

fetch_list	: STRING		{save_str(&current.domainlist, $1,TRUE);}
		| fetch_list STRING	{save_str(&current.domainlist, $2,TRUE);}
		;

num_list	: NUMBER
			{
			    struct idlist *id;
			    id=save_str(&current.antispam,STRING_DUMMY,0);
			    id->val.status.num = $1;
			}
		| num_list NUMBER
			{
			    struct idlist *id;
			    id=save_str(&current.antispam,STRING_DUMMY,0);
			    id->val.status.num = $2;
			}
		;

user_option	: TO localnames HERE
		| TO localnames
		| IS localnames HERE
		| IS localnames

		| IS STRING THERE	{current.remotename  = xstrdup($2);}
		| PASSWORD STRING	{current.password    = xstrdup($2);}
		| FOLDER folder_list
		| SMTPHOST smtp_list
		| FETCHDOMAINS fetch_list
		| SMTPADDRESS STRING	{current.smtpaddress = xstrdup($2);}
		| SMTPNAME STRING	{current.smtpname = xstrdup($2);}
		| SPAMRESPONSE num_list
		| MDA STRING		{current.mda         = xstrdup($2);}
		| BSMTP STRING		{current.bsmtp       = prependdir ($2, rcfiledir);}
		| LMTP			{current.listener    = LMTP_MODE;}
		| PRECONNECT STRING	{current.preconnect  = xstrdup($2);}
		| POSTCONNECT STRING	{current.postconnect = xstrdup($2);}

		| KEEP			{current.keep        = FLAG_TRUE;}
		| FLUSH			{current.flush       = FLAG_TRUE;}
		| FETCHALL		{current.fetchall    = FLAG_TRUE;}
		| REWRITE		{current.rewrite     = FLAG_TRUE;}
		| FORCECR		{current.forcecr     = FLAG_TRUE;}
		| STRIPCR		{current.stripcr     = FLAG_TRUE;}
		| PASS8BITS		{current.pass8bits   = FLAG_TRUE;}
		| DROPSTATUS		{current.dropstatus  = FLAG_TRUE;}
                | DROPDELIVERED         {current.dropdelivered = FLAG_TRUE;}
		| MIMEDECODE		{current.mimedecode  = FLAG_TRUE;}
		| IDLE			{current.idle        = FLAG_TRUE;}

		| SSL 	                {
#ifdef SSL_ENABLE
		    current.use_ssl = FLAG_TRUE;
#else
		    yyerror(GT_("SSL is not enabled"));
#endif 
		}
		| SSLKEY STRING		{current.sslkey = prependdir ($2, rcfiledir);}
		| SSLCERT STRING	{current.sslcert = prependdir ($2, rcfiledir);}
		| SSLPROTO STRING	{current.sslproto = xstrdup($2);}
		| SSLCERTCK             {current.sslcertck = FLAG_TRUE;}
		| SSLCERTPATH STRING    {current.sslcertpath = prependdir($2, rcfiledir);}
		| SSLFINGERPRINT STRING {current.sslfingerprint = xstrdup($2);}

		| NO KEEP		{current.keep        = FLAG_FALSE;}
		| NO FLUSH		{current.flush       = FLAG_FALSE;}
		| NO FETCHALL		{current.fetchall    = FLAG_FALSE;}
		| NO REWRITE		{current.rewrite     = FLAG_FALSE;}
		| NO FORCECR		{current.forcecr     = FLAG_FALSE;}
		| NO STRIPCR		{current.stripcr     = FLAG_FALSE;}
		| NO PASS8BITS		{current.pass8bits   = FLAG_FALSE;}
		| NO DROPSTATUS		{current.dropstatus  = FLAG_FALSE;}
                | NO DROPDELIVERED      {current.dropdelivered = FLAG_FALSE;}
		| NO MIMEDECODE		{current.mimedecode  = FLAG_FALSE;}
		| NO IDLE		{current.idle        = FLAG_FALSE;}

		| NO SSL 	        {current.use_ssl     = FLAG_FALSE;}

		| LIMIT NUMBER		{current.limit       = NUM_VALUE_IN($2);}
		| WARNINGS NUMBER	{current.warnings    = NUM_VALUE_IN($2);}
		| FETCHLIMIT NUMBER	{current.fetchlimit  = NUM_VALUE_IN($2);}
		| BATCHLIMIT NUMBER	{current.batchlimit  = NUM_VALUE_IN($2);}
		| EXPUNGE NUMBER	{current.expunge     = NUM_VALUE_IN($2);}

		| PROPERTIES STRING	{current.properties  = xstrdup($2);}
		;
%%

/* lexer interface */
extern char *rcfile;
extern int prc_lineno;
extern char *yytext;
extern FILE *yyin;

static struct query *hosttail;	/* where to add new elements */

void yyerror (const char *s)
/* report a syntax error */
{
    report_at_line(stderr, 0, rcfile, prc_lineno, GT_("%s at %s"), s, 
		   (yytext && yytext[0]) ? yytext : GT_("end of input"));
    prc_errflag++;
}

int prc_filecheck(const char *pathname, const flag securecheck)
/* check that a configuration file is secure */
{
#ifndef __EMX__
    struct stat statbuf;

    errno = 0;

    /* special case useful for debugging purposes */
    if (strcmp("/dev/null", pathname) == 0)
	return(PS_SUCCESS);

    /* pass through the special name for stdin */
    if (strcmp("-", pathname) == 0)
	return(PS_SUCCESS);

    /* the run control file must have the same uid as the REAL uid of this 
       process, it must have permissions no greater than 600, and it must not 
       be a symbolic link.  We check these conditions here. */

    if (lstat(pathname, &statbuf) < 0) {
	if (errno == ENOENT) 
	    return(PS_SUCCESS);
	else {
	    report(stderr, "lstat: %s: %s\n", pathname, strerror(errno));
	    return(PS_IOERR);
	}
    }

    if (!securecheck)	return PS_SUCCESS;

    if ((statbuf.st_mode & S_IFLNK) == S_IFLNK)
    {
	fprintf(stderr, GT_("File %s must not be a symbolic link.\n"), pathname);
	return(PS_IOERR);
    }

#ifndef __BEOS__
    if (statbuf.st_mode & ~(S_IFREG | S_IREAD | S_IWRITE | S_IEXEC | S_IXGRP))
    {
	fprintf(stderr, GT_("File %s must have no more than -rwx--x--- (0710) permissions.\n"), 
		pathname);
	return(PS_IOERR);
    }
#endif /* __BEOS__ */

#ifdef HAVE_GETEUID
    if (statbuf.st_uid != geteuid())
#else
    if (statbuf.st_uid != getuid())
#endif /* HAVE_GETEUID */
    {
	fprintf(stderr, GT_("File %s must be owned by you.\n"), pathname);
	return(PS_IOERR);
    }
#endif
    return(PS_SUCCESS);
}

int prc_parse_file (const char *pathname, const flag securecheck)
/* digest the configuration into a linked list of host records */
{
    prc_errflag = 0;
    querylist = hosttail = (struct query *)NULL;

    errno = 0;

    /* Check that the file is secure */
    if ( (prc_errflag = prc_filecheck(pathname, securecheck)) != 0 )
	return(prc_errflag);

    /*
     * Croak if the configuration directory does not exist.
     * This probably means an NFS mount failed and we can't
     * see a configuration file that ought to be there.
     * Question: is this a portable check? It's not clear
     * that all implementations of lstat() will return ENOTDIR
     * rather than plain ENOENT in this case...
     */
    if (errno == ENOTDIR)
	return(PS_IOERR);
    else if (errno == ENOENT)
	return(PS_SUCCESS);

    /* Open the configuration file and feed it to the lexer. */
    if (strcmp(pathname, "-") == 0)
	yyin = stdin;
    else if ((yyin = fopen(pathname,"r")) == (FILE *)NULL) {
	report(stderr, "open: %s: %s\n", pathname, strerror(errno));
	return(PS_IOERR);
    }

    yyparse();		/* parse entire file */

    fclose(yyin);	/* not checking this should be safe, file mode was r */

    if (prc_errflag) 
	return(PS_SYNTAX);
    else
	return(PS_SUCCESS);
}

static void reset_server(const char *name, int skip)
/* clear the entire global record and initialize it with a new name */
{
    trailer = FALSE;
    memset(&current,'\0',sizeof(current));
    current.smtp_socket = -1;
    current.server.pollname = xstrdup(name);
    current.server.skip = skip;
    current.server.principal = (char *)NULL;
}


static void user_reset(void)
/* clear the global current record (user parameters) used by the parser */
{
    struct hostdata save;

    /*
     * Purpose of this code is to initialize the new server block, but
     * preserve whatever server name was previously set.  Also
     * preserve server options unless the command-line explicitly
     * overrides them.
     */
    save = current.server;

    memset(&current, '\0', sizeof(current));
    current.smtp_socket = -1;

    current.server = save;
}

struct query *hostalloc(init)
/* append a host record to the host list */
struct query *init;	/* pointer to block containing initial values */
{
    struct query *node;

    /* allocate new node */
    node = (struct query *) xmalloc(sizeof(struct query));

    /* initialize it */
    if (init)
	memcpy(node, init, sizeof(struct query));
    else
    {
	memset(node, '\0', sizeof(struct query));
	node->smtp_socket = -1;
    }

    /* append to end of list */
    if (hosttail != (struct query *) 0)
	hosttail->next = node;	/* list contains at least one element */
    else
	querylist = node;	/* list is empty */
    hosttail = node;

    if (trailer)
	node->server.lead_server = leadentry;
    else
    {
	node->server.lead_server = NULL;
	leadentry = &node->server;
    }

    return(node);
}

static void record_current(void)
/* register current parameters and append to the host list */
{
    (void) hostalloc(&current);
    trailer = TRUE;
}

char *prependdir (const char *file, const char *dir)
/* if a filename is relative to dir, convert it to an absolute path */
{
    char *newfile;
    if (!file[0] ||			/* null path */
	file[0] == '/' ||		/* absolute path */
	strcmp(file, "-") == 0 ||	/* stdin/stdout */
	!dir[0])			/* we don't HAVE_GETCWD */
	return xstrdup (file);
    newfile = xmalloc (strlen (dir) + 1 + strlen (file) + 1);
    if (dir[strlen(dir) - 1] != '/')
	sprintf (newfile, "%s/%s", dir, file);
    else
	sprintf (newfile, "%s%s", dir, file);
    return newfile;
}

/* easier to do this than cope with variations in where the library lives */
int yywrap(void) {return 1;}

/* rcfile_y.y ends here */

