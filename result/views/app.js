var app = angular.module('catsvsdogs', []);
var socket = io.connect();

app.controller('statsCtrl', function($scope, $timeout) {
  $scope.a = 0;
  $scope.b = 0;
  $scope.total = 0;
  $scope.aPercent = 50;
  $scope.bPercent = 50;
  $scope.viewsCount = 241;
  $scope.shareCount = 12;

  $scope.currentSubjectIdx = 0;
  $scope.subjects = [
    {
      title: "Do you like this Car?",
      greeting: "Hi Guys!",
      image: "images/car.jpg",
      optionA: "Yes!",
      optionB: "No!"
    },
    {
      title: "Do you like this Cat?",
      greeting: "Hi Faza!",
      image: "images/cat.jpg",
      optionA: "Yes!",
      optionB: "No!"
    }
  ];
  $scope.currentSubject = $scope.subjects[0];

  $scope.recentVotes = [
    { name: 'Nola Sofyan', choice: 'Yes!', type: 'a', avatar: '👩🏻‍🦰', bg: '#fca5a5' },
    { name: 'Zhofran', choice: 'Yes!', type: 'a', avatar: '👨🏼‍🦱', bg: '#86efac' },
    { name: 'Faza', choice: 'Cats!', type: 'a', avatar: '🧑🏻', bg: '#fde047' },
    { name: 'Alex M.', choice: 'No!', type: 'b', avatar: '🧔🏻‍♂️', bg: '#93c5fd' }
  ];

  $scope.toggleSubject = function() {
    $scope.currentSubjectIdx = ($scope.currentSubjectIdx + 1) % $scope.subjects.length;
    $scope.currentSubject = $scope.subjects[$scope.currentSubjectIdx];
  };

  var updateScores = function() {
    socket.on('scores', function(json) {
      var data = JSON.parse(json);
      var a = parseInt(data.a || 0);
      var b = parseInt(data.b || 0);
      var newTotal = a + b;

      var percentages = getPercentages(a, b);

      $scope.$apply(function() {
        var prevTotal = $scope.total;
        $scope.a = a;
        $scope.b = b;
        $scope.total = newTotal;
        $scope.aPercent = percentages.a;
        $scope.bPercent = percentages.b;
        $scope.viewsCount = 241 + newTotal;

        // If new vote arrived, prepend activity
        if (newTotal > prevTotal && prevTotal > 0) {
          var votedFor = (a > $scope.prevA) ? 'Yes!' : 'No!';
          var votedType = (a > $scope.prevA) ? 'a' : 'b';
          var sampleNames = ['Sari W.', 'Kenji', 'Dina', 'Rian P.', 'Devon'];
          var randomName = sampleNames[Math.floor(Math.random() * sampleNames.length)];
          $scope.recentVotes.unshift({
            name: randomName,
            choice: 'Voted ' + votedFor,
            type: votedType,
            avatar: '✨',
            bg: votedType === 'a' ? '#86efac' : '#93c5fd'
          });
          if ($scope.recentVotes.length > 5) {
            $scope.recentVotes.pop();
          }
        }
        $scope.prevA = a;
        $scope.prevB = b;
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