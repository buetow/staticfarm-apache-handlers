# (C) 2013 Paul Buetow

package StaticFarm::CacheControl;

use strict;
use warnings;

use Apache2::Const -compile => qw(HTTP_OK HTTP_NO_CONTENT HTTP_NOT_FOUND);
use Apache2::Log;
use Apache2::RequestIO;
use Apache2::RequestRec;
use Apache2::Response;
use Apache2::ServerUtil;
use APR::Table;

use File::Basename;
use File::Copy qw(move);
use File::MimeInfo;
use File::Path qw(make_path);
use LWP::Simple qw($ua getstore);

my $FETCH_FALLBACK_ENABLE = $ENV{CACHECONTROL_FETCH_FALLBACK_ENABLE};
my $FETCH_FALLBACK_HOSTSDIR = $ENV{CACHECONTROL_FETCH_FALLBACK_HOSTSDIR};
my $FETCH_MW_HA_HOST = $ENV{CACHECONTROL_FETCH_MW_HA_HOST};
my $FETCH_PROTO = $ENV{CACHECONTROL_FETCH_PROTO};
my $FETCH_REASK_AFTER = $ENV{CACHECONTROL_FETCH_REASK_AFTER};
my $FETCH_TIMEOUT = $ENV{CACHECONTROL_FETCH_TIMEOUT};
my $FETCH_MAX_LIMIT = $ENV{CACHECONTROL_FETCH_MAX_LIMIT};
my $FETCH_MAX_INTERVAL = $ENV{CACHECONTROL_FETCH_MAX_INTERVAL};
my $VERBOSE = $ENV{CACHECONTROL_WARN_VERBOSE};

# ... now setup some serious stuff!!
my $SERVER_ROOT = Apache2::ServerUtil::server_root();
my $DOCUMENT_ROOT = "$SERVER_ROOT/htdocs";
my $RUN_DIR = "$SERVER_ROOT/run";
my $STATIC_ROOT = "$DOCUMENT_ROOT/static";
my $DOT_RE = qr/\.\./;
my $QRY_RE = qr/\?.*/;
my $IGNORE_RE = qr/favicon.ico/;

# TMP_DIR is in DOCUMENT_ROOT due FS performance issue (must be on same partition)
my $TMP_DIR = "$RUN_DIR/cachetmp";

my %NOT_FOUND;
my $FETCH_MAX_COUNTER = 0;
my $FETCH_MAX_TIME = 0;

sub my_warn {
  my $msg = shift;

  Apache2::ServerRec::warn("CacheControl: $msg");
}

sub my_response {
  my ($r, $what, $msg) = @_;

  $r->custom_response($what, "<body><html>$msg</html></body>");

  return $what;
}

sub my_getstore {
  my ($url, $tmp_file) = @_;

  my_warn("Fetching $url -> $tmp_file with timeout $FETCH_TIMEOUT") if $VERBOSE == 1;

  $ua->timeout($FETCH_TIMEOUT);
  my $http_code = getstore($url, $tmp_file); 

  if ($http_code >= 301) {
    unlink $tmp_file if -f $tmp_file;

    my_warn("Document $url not fetchable (HTTP status is $http_code)");
  }

  return $http_code;
}

sub handler {
  my $r = shift;

  return fetch_file($r);
}

sub get_fallback_mw_hosts {
  opendir my $dh, $FETCH_FALLBACK_HOSTSDIR or return ();

  my @fallbacks;
  while (my $d = readdir($dh)) { 
    next if $d =~ /^\./;
    push @fallbacks, $d;
  }
  close $dh;

  return @fallbacks;
}
sub fetch_file {
  my $r = shift;

  unless (-e $STATIC_ROOT) {
    my_warn("Static root $STATIC_ROOT does not exist.");
    return my_response($r, Apache2::Const::HTTP_NOT_FOUND, "File not found!");
  }

  my $request_uri = $ENV{REQUEST_URI}; 
  $request_uri =~ s/$DOT_RE//g;
  $request_uri =~ s/$QRY_RE//;

  my $mw_url = "$FETCH_PROTO://$FETCH_MW_HA_HOST/static/$ENV{SERVER_NAME}";
  my $file = "$STATIC_ROOT/$ENV{SERVER_NAME}$request_uri";
  my $basename = basename($file);
  my $tmp_file = "$TMP_DIR/$basename";

  if ($request_uri =~ $IGNORE_RE) {
    my_warn("Ignoring $file, don't try to fetch from MW");
    return my_response($r, Apache2::Const::HTTP_NOT_FOUND, "File not found!");
  }

  $r->uri($request_uri);

  unless (-e $TMP_DIR) {
    my_warn("Creating directory $TMP_DIR") if $VERBOSE == 1;
    make_path($TMP_DIR);
  }

  my $now = time();
  # Prevent DOS attacks against the middleware server
  if (++$FETCH_MAX_COUNTER > $FETCH_MAX_LIMIT) {
    if ($now - $FETCH_MAX_TIME > $FETCH_MAX_INTERVAL) {
      $FETCH_MAX_COUNTER = 1;
      $FETCH_MAX_TIME= $now;
    } else {
      my_warn("Don't try to fetch $request_uri from mw, because in FETCH_MAX_INTERVAL=$FETCH_MAX_INTERVAL seconds we had already $FETCH_MAX_COUNTER tries but FETCH_MAX_LIMIT=$FETCH_MAX_LIMIT seconds");
      return my_response($r, Apache2::Const::HTTP_NOT_FOUND, "File not found!");
      #return Apache2::Const::HTTP_NOT_FOUND;
    }
  }

  if ($FETCH_REASK_AFTER != 0 && exists $NOT_FOUND{$request_uri}) {
    my $last_access = $now - $NOT_FOUND{$request_uri};
    if ($last_access < $FETCH_REASK_AFTER) {
      my_warn("Don't try to fetch $request_uri from mw, because you can ask for this file only 1 time within FETCH_REASK_AFTER=$FETCH_REASK_AFTER seconds");
      return my_response($r, Apache2::Const::HTTP_NOT_FOUND, "File not found!");
      #return Apache2::Const::HTTP_NOT_FOUND;
    } else {
      delete $NOT_FOUND{$request_uri};
    }
  }

  my $url = "$FETCH_PROTO://$FETCH_MW_HA_HOST/static/$ENV{SERVER_NAME}/$request_uri";
  my $http_code = my_getstore($url, $tmp_file);

  if ($http_code >= 500 && $FETCH_FALLBACK_ENABLE == 1) {
    # The staticmw ha address (FETCH_MW_HA_HOST) is not reachable or broken, try fallback MW hosts
    for (get_fallback_mw_hosts()) {
      $url = "$FETCH_PROTO://$_/static/$ENV{SERVER_NAME}/$request_uri";
      $http_code = my_getstore($url, $tmp_file);
      last if $http_code < 400;
    }
  } 

  if ($http_code >= 301) {
    $NOT_FOUND{$request_uri} = time() if $FETCH_REASK_AFTER != 0;
    return my_response($r, Apache2::Const::HTTP_NOT_FOUND, "File not found!");
    #return Apache2::Const::HTTP_NOT_FOUND;

  } else {
    my $dirname = dirname($file);

    unless (-d $dirname) {
      my_warn("Creating directory $dirname") if $VERBOSE == 1;
      make_path($dirname);
    }

    my_warn("Moving $tmp_file -> $file") if $VERBOSE == 1;

    unless (move($tmp_file, $file)) {
      my_warn("Could not move file $tmp_file -> $file: $!");
      return Apache2::Const::HTTP_NO_CONTENT;
    }

    open my $fh, $file or do {
      my_warn("Could not open file $file: $!");
      return Apache2::Const::HTTP_NO_CONTENT;
    };

    $r->content_type(mimetype($file));
    print while <$fh>;
    close $fh;

    return Apache2::Const::OK;
  }
}

1;
