
#' @title Ensembles of elastic net algorithm with a sparsity and diversity penalty.
#' @param x Design matrix.
#' @param y Response vector.
#' @param num_lambdas_sparsity Number of penalty parameters for the individual coefficients.
#' @param num_lambdas_diversity Number of penalty parameters for the interactions between groups.
#' @param alpha Elastic Net tuning constant: the value must be between 0 and 1. Default is 1 (Lasso).
#' @param num_groups Number of groups for the objective function.
#' @param tolerance Tolerance parameter to stop the iterations while cycling over the groups.
#' @param max_iter Maximum number of iterations before stopping the iterations while cycling over the groups.
#' @param num_folds Number of folds for the CV.
#' @param num_threads Number of threads used for parallel computation over the folds.

#' @return An object of class ensembleEN, a list with entries
#' \item{betas}{Coefficients computed over the path of penalties for sparsity; the penalty for diversity is fixed at the optimal value.}
#' \item{intercepts}{Intercepts for each of the models along the path of penalties for sparsity.}
#' \item{index_opt}{Index of the optimal penalty parameter for sparsity.}
#' \item{lambda_sparsity_opt}{Optimal penalty parameter for sparsity.}
#' \item{lambda_diversity_opt}{Optimal penalty parameter for diversity.}
#' \item{lambdas_sparsity}{Grid of sparsity parameters.}
#' \item{lambdas_diversity}{Grid of diversity parameters.}
#' \item{cv_mse_sparsity}{Cross-validated prediction MSEs over the grid of sparsity penalties.}
#' \item{cv_mse_diversity}{Cross-validated prediction MSEs over the grid of diversity penalties.}
#' \item{cv_opt}{Optimal CV MSE.}

#' 
#' @description
#' Computes an ensemble of Elastic Net regularized linear models. The sparsity and diversity penalty
#' parameters are chosen automatically.
#' 
#' @details
#' Computes and ensemble of \code{num_groups} (\eqn{G}) Elastic Net regularized linear models, defined as the linear models
#' \eqn{\boldsymbol{\beta}^{1},\dots, \boldsymbol{\beta}^{G}} that minimize
#' \deqn{\sum\limits_{g=1}^{G}\left( \frac{1}{2n}\Vert \mathbf{y}-\mathbf{X} \boldsymbol{\beta}^{g}\Vert^{2} 
#' +\lambda_{S}\left( \frac{(1-\alpha)}{2}\Vert \boldsymbol{\beta}^{g}\Vert_{2}^{2}+\alpha \Vert \boldsymbol{
#' \beta \Vert_1}\right)+\frac{\lambda_{D}}{2}\sum\limits_{h\neq g}\sum_{j=1}^{p}\vert \beta_{j}^{h}\beta_{j}^{g}\vert \right),}
#' over grids for the penalty parameters \eqn{\lambda_{S}} and \eqn{\lambda_{D}} that are chosen automatically by the program.
#' Larger values of \eqn{\lambda_{S}} encourage more sparsity within the models and larger values of \eqn{\lambda_{D}} encourage more diversity
#' among them. 
#' If \eqn{\lambda_{D}=0}, then all of the models in the ensemble are equal to the Elastic Net regularized
#' least squares estimator with penalty parameter \eqn{\lambda_{S}}. Optimal penalty parameters are found by
#' \code{num_folds} cross-validation, where the prediction of the ensemble is formed by simple averaging.
#' The predictors and the response are standardized to zero mean and unit variance before any computations are performed.
#' The final output is in the original scales.
#' 
#' @seealso \code{\link{predict.ensembleEN}}, \code{\link{coef.ensembleEN}}
#' 
#' @examples 
#' library(MASS)
#' set.seed(1)
#' beta <- c(0, 1, 1)
#' Sigma <- diag(1, 3, 3)
#' Sigma[2, 3] <- Sigma[3, 2] <- 0.9
#' x <- mvrnorm(10, mu = rep(0, 3), Sigma = Sigma)
#' y <- x %*% beta + rnorm(10)
#' fit <- ensembleEN(x, y, num_groups=2)
#' coefs <- predict(fit, type="coefficients")
#' 

ensembleEN <- function(x, y, num_lambdas_sparsity = 100, num_lambdas_diversity = 100, alpha = 1, num_groups = 10,
                       tolerance = 1e-7, max_iter = 1e5, num_folds = 10, num_threads = 1){
  # Some sanity checks on the input
  if (all(!inherits(x, "matrix"), !inherits(x, "data.frame"))) {
    stop("x should belong to one of the following classes: matrix, data.frame")
  } else if (all(!inherits(y, "matrix"), all(!inherits(y, "numeric")))) {
    stop("y should belong to one of the following classes: matrix, numeric")
  } else if (any(anyNA(x), any(is.nan(x)), any(is.infinite(x)))) {
    stop("x should not have missing, infinite or nan values")
  } else if (any(anyNA(y), any(is.nan(y)), any(is.infinite(y)))) {
    stop("y should not have missing, infinite or nan values")
  } else {
    if(inherits(y, "matrix")) {
      if (ncol(y)>1){
        stop("y should be a vector")
      }
      # Force to vector if input was a matrix
      y <- as.numeric(y)
    }
    len_y <- length(y)
    if (len_y != nrow(x)) {
      stop("y and x should have the same number of rows")
    }
  }
  if (!inherits(tolerance, "numeric")) {
    stop("tolerance should be numeric")
  } else if (!all(tolerance < 1, tolerance > 0)) {
    stop("tolerance should be between 0 and 1")
  }
  if (!inherits(alpha, "numeric")) {
    stop("alpha should be numeric")
  } else if (!all(alpha <= 1, alpha > 0)) {
    stop("alpha should be between 0 and 1")
  }
  if (!inherits(max_iter, "numeric")) {
    stop("max_iter should be numeric")
  } else if (any(!max_iter == floor(max_iter), max_iter <= 0)) {
    stop("max_iter should be a positive integer")
  }
  if (!inherits(num_lambdas_sparsity, "numeric")) {
    stop("num_lambdas_sparsity should be numeric")
  } else if (any(!num_lambdas_sparsity == floor(num_lambdas_sparsity), num_lambdas_sparsity <= 0)) {
    stop("num_lambdas_sparsity should be a positive integer")
  }
  if (!inherits(num_lambdas_diversity, "numeric")) {
    stop("num_lambdas_diversity should be numeric")
  } else if (any(!num_lambdas_diversity == floor(num_lambdas_diversity), num_lambdas_diversity <= 0)) {
    stop("num_lambdas_diversity should be a positive integer")
  }
  
  # Shuffle the data
  n <- nrow(x)
  random.permutation <- sample(1:n, n)
  x.permutation <- x[random.permutation, ]
  y.permutation <- y[random.permutation]
  
  output <- Main_Ensemble_EN(x.permutation, y.permutation, num_lambdas_sparsity, num_lambdas_diversity, alpha, num_groups, 
                             tolerance, max_iter, num_folds, num_threads)
  output <- construct.ensembleEN(output, x, y)
  return(output)
}

