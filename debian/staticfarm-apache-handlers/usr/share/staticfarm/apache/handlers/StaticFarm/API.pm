package StaticFarm::API;

use strict;
use warnings;

use Apache2::Const -compile => qw(:common);
use Apache2::RequestIO ();
use Apache2::RequestRec ();
use Apache2::ServerUtil;

use ExtUtils::Command;

use File::Path qw(remove_tree);
use JSON; 
use POSIX qw(strftime ctime);

use constant IOBUFSIZE => 8192;

my $CONTENT_DIR = $ENV{API_CONTENT_DIR};

# ... now setup some serious stuff!!
my $URI_PREFIX = '/-api';

sub handler {
  my $r = shift;
  $r->content_type('application/json');

  my $method = $r->method();

  my $d = {
    method => $method,
    uri => $r->uri(),
    args => $r->args(),
    out => { message => "" },
  };

  ($d->{path}) = $r->uri() =~ /^$URI_PREFIX(.*)/;
  $d->{fullpath} = "$CONTENT_DIR$d->{path}";

  my %params = map { 
  s/\.\.//g; 
  my ($k, $v) = split '=', $_;
  $v //= '';
  $k => $v;
  } split '&', $r->args();

  $d->{params} = \%params;

  if ($method eq 'GET') {
    handler_get($r, $d);

  } elsif ($method eq 'DELETE') {
    handler_delete($r, $d);

  } elsif ($method eq 'POST') {
    handler_post($r, $d);

  } elsif ($method eq 'PUT') {
    handler_put($r, $d);

  } else {
    handler_unknown($r, $d);
  }

  return Apache2::Const::DONE;
}

sub data_out {
  my ($r, $d, $status, $message) = @_;
  my $p = $d->{params};

  $d->{out}{message} = $message if defined $message;
  $d->{out}{fullpath} = $d->{fullpath};

  $status //= 200;
  $d->{out}{status} = $status;
  $r->status($status);

  if (exists $p->{debug} and $p->{debug} == 1) {
    for (grep !/^out$/, keys %$d) {
      $d->{out}{debug}{$_} = $d->{$_};
    }
  }

  print JSON->new->allow_nonref->pretty->encode($d->{out});
}

sub my_time {
  return strftime("%Y-%m-%d %H:%M:%S", localtime(shift));
}

sub path_stat {
  my $f = shift;

  my @stat = stat($f);

  my %data = (
    size => -s $f,
    hardlinks => $stat[3],
    uid => $stat[4],
    gid => $stat[5],
    last_access => my_time($stat[8]),
    last_modified => my_time($stat[9]),
    last_status_change => my_time($stat[10]),
    blocks => $stat[12],
    ascii => (-T $f eq '' ? 0 : 1),
    is_directory => (-d $f eq '' ? 0 : 1),
    is_symlink => (-l $f eq '' ? 0 : 1),
    is_file => (-f $f eq '' ? 0 : 1),
  );

  return \%data;
}

sub path_ls {
  my $f = shift;

  return [ map { s#.*/##; $_ } glob("$f/*") ];
}

sub path_exists {
  my ($r, $d) = @_;

  unless ( -e $d->{fullpath}) {
    data_out($r, $d, 404, "No such file or directory: $d->{fullpath}");
    return 0;
  }

  return 1;
}

sub path_writable {
  my ($r, $d) = @_;

  if (-e $d->{fullpath} && ! -w $d->{fullpath}) {
    data_out($r, $d, 403, "Error: $d->{fullpath} permission denied.");
    return 0;
  }

  return 1;
}

sub path_write {
  my ($r, $d, $content) = @_;

  return unless path_writable($r, $d);

  if (defined $content) {
    if ( -f $d->{fullpath} or ! -e $d->{fullpath} ) {
      open my $fh, '>', $d->{fullpath} or do {
        $d->{out}{message} = "Error: $d->{fullpath} $!";
        data_out($r, $d, 500);
        return;
      };

      print $fh $content;
      close $fh;

      $d->{out}{message} = "Wrote file successfully.";
    } else {
      data_out($r, $d, 500, "Can't put or post content like that. Destination may be a directory.");
      return;
    }

  } else {
    system("/usr/bin/touch \"$d->{fullpath}\"");
    $d->{out}{message} = "Touched file or directory successfully.";
  } 

  $d->{out}{stat} = path_stat($d->{fullpath});
  data_out($r, $d);
}


sub handler_get {
  my ($r, $d) = @_;
  my $p = $d->{params};

  return unless path_exists($r, $d);

  $d->{out}{stat} = path_stat($d->{fullpath});
  $d->{out}{content} = path_ls($d->{fullpath}) 
  if -d $d->{fullpath} and exists $p->{ls} and $p->{ls} == 1;

  data_out($r, $d, 200);
}

sub handler_delete {
  my ($r, $d) = @_;
  my $p = $d->{params};

  return unless path_exists($r, $d);

  $d->{out}{stat} = path_stat($d->{fullpath});

  if ( -d $d->{fullpath} ) {
    if (exists $p->{iamsure} and $p->{iamsure} == 1) {
      my $err;
      remove_tree($d->{fullpath}, { error => \$err });  
      unless (@$err) {
        data_out($r, $d, 200, 'Directory deleted successfully.');
      } else {
        data_out($r, $d, 500, "Directory could not deleted completely. Run ls to see what's left over.");
      }
    } else {
      data_out($r, $d, 403, 'Not removing directory recursively. If you want to do this set iamsure=1.');
    }

  } elsif ( -f $d->{fullpath} ) {
    if (unlink($d->{fullpath})) {
      data_out($r, $d, 200, 'File deleted successfully.');
    } else {
      data_out($r, $d, 500, "Error deleting: $d->{fullpath} $!.");
    }
  }
}


sub handler_post {
  my ($r, $d) = @_;
  my ($content, $buffer, $len) = ('', '', IOBUFSIZE);

  $content .= $buffer while $r->read($buffer, $len);
  path_write($r, $d, $content);
}

sub handler_put {
  my ($r, $d) = @_;
  my $p = $d->{params};

  my $content = do {
    if (exists $p->{content}) {
      $p->{content};
    } else {
      undef;  
    }
  };  

  path_write($r, $d, $content);
}

sub handler_unknown {
  my ($r, $d) = @_;

  data_out($r, $d, 501, "Method $d->{method} is not implemented.");
}

1;
