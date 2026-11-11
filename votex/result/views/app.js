var app = angular.module('catsvsdogs', []);
var socket = io.connect();

app.controller('statsCtrl', function($scope, $http, $timeout) {
  $scope.a = 0;
  $scope.b = 0;
  $scope.total = 0;
  $scope.pollVotes = 0;
  $scope.aPercent = 50;
  $scope.bPercent = 50;
  $scope.viewsCount = 0;
  $scope.shareCount = 0;
  $scope.engagementRate = '100%';
  $scope.voteUrl = '/';

  $scope.currentSubjectIdx = 0;
  $scope.subjects = [
    {
      id: "cats-dogs",
      title: "Do you like this Cat? (Cats vs Dogs)",
      greeting: "Hi Faza!",
      image: "images/cat.jpg",
      optionA: "Cats",
      optionB: "Dogs"
    },
    {
      id: "vintage-car",
      title: "Do you like this Classic Beetle Car?",
      greeting: "Hi Guys!",
      image: "images/car.jpg",
      optionA: "Yes!",
      optionB: "No!"
    },
    {
      id: "coffee-tea",
      title: "Morning Fuel: Coffee or Tea?",
      greeting: "Good Morning!",
      image: "https://images.unsplash.com/photo-1514432324607-a09d9b4aefdd?w=800&q=80",
      optionA: "Coffee ☕",
      optionB: "Tea 🍵"
    }
  ];
  $scope.currentSubject = $scope.subjects[0];

  $scope.recentVotes = [];
  var lastPayload = null;

  // Load dynamic configuration from server
  $http.get('/api/config').then(function(res) {
    if (res.data && res.data.vote_url) {
      $scope.voteUrl = res.data.vote_url;
      updateNavigationLinks(res.data.vote_url);
    }
  }, function(err) {
    console.warn("Could not load /api/config", err);
  });

  $scope.toggleSubject = function() {
    $scope.currentSubjectIdx = ($scope.currentSubjectIdx + 1) % $scope.subjects.length;
    $scope.currentSubject = $scope.subjects[$scope.currentSubjectIdx];
    if (lastPayload) {
      applyPayload(lastPayload);
    }
  };

  function applyPayload(data) {
    var currentPollId = $scope.currentSubject.id;
    var pollScore = (data.polls && data.polls[currentPollId]) ? data.polls[currentPollId] : { a: 0, b: 0, total: 0 };

    var a = parseInt(pollScore.a || 0, 10);
    var b = parseInt(pollScore.b || 0, 10);
    var pollTotal = a + b;
    var percentages = getPercentages(a, b);

    $scope.a = a;
    $scope.b = b;
    $scope.total = parseInt(data.total || 0, 10);
    $scope.pollVotes = pollTotal;
    $scope.aPercent = percentages.a;
    $scope.bPercent = percentages.b;
    $scope.viewsCount = parseInt(data.uniqueVoters || 0, 10);
    $scope.shareCount = Math.max(0, Math.floor($scope.total / 4));
    $scope.engagementRate = ($scope.viewsCount > 0)
      ? Math.min(100, Math.round(($scope.total / $scope.viewsCount) * 100)) + '%'
      : '100%';

    if (data.recentVotes && data.recentVotes.length > 0) {
      $scope.recentVotes = data.recentVotes.map(function(v) {
        var choiceName = v.type === 'a' ? $scope.currentSubject.optionA : $scope.currentSubject.optionB;
        return {
          name: v.name,
          choice: 'Voted ' + (v.choice || choiceName),
          type: v.type,
          avatar: v.avatar || '🗳️',
          bg: v.bg || (v.type === 'a' ? '#86efac' : '#93c5fd')
        };
      });
    }
  }

  var updateScores = function() {
    socket.on('scores', function(json) {
      var data = JSON.parse(json);
      lastPayload = data;

      $scope.$apply(function() {
        applyPayload(data);
      });
    });
  };

  var init = function() {
    document.body.style.opacity = 1;
    updateScores();
  };

  socket.on('message', function(data) {
    init();
  });
});

function updateNavigationLinks(voteUrl) {
  var links = document.querySelectorAll('a[data-vote-link]');
  links.forEach(function(l) {
    l.setAttribute('href', voteUrl);
  });
}

function getPercentages(a, b) {
  var result = {};
  if (a + b > 0) {
    result.a = Math.round((a / (a + b)) * 100);
    result.b = 100 - result.a;
  } else {
    result.a = 50;
    result.b = 50;
  }
  return result;
}

// Live Clock in status bar
function startLiveClock() {
  function update() {
    var el = document.getElementById('live-time');
    if (!el) return;
    var now = new Date();
    var h = now.getHours().toString().padStart(2, '0');
    var m = now.getMinutes().toString().padStart(2, '0');
    el.innerText = h + ':' + m;
  }
  setInterval(update, 1000);
  update();
}
document.addEventListener('DOMContentLoaded', startLiveClock);
